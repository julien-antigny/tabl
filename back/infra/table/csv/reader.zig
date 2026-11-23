const std = @import("std");
const Records = @import("records.zig").Records;
const Fields = @import("fields.zig").Fields;
const Separator = @import("separator.zig").Separator;
const detectSeparator = @import("separator.zig").detect;

const bom = "\xEF\xBB\xBF";

pub const CsvReader = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    path: []const u8,
    file: ?std.Io.File = null,
    map: ?std.Io.File.MemoryMap = null,
    bytes: []const u8 = "",
    opened: bool = false,
    records: Records = .{ .bytes = "" },
    separator: Separator = .comma,
    names: std.ArrayList([]const u8) = .empty,
    header_loaded: bool = false,

    pub fn new(
        io: std.Io,
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        path: []const u8,
    ) CsvReader {
        return .{ .io = io, .allocator = allocator, .dir = dir, .path = path };
    }

    pub fn close(self: *CsvReader) void {
        self.names.deinit(self.allocator);
        self.names = .empty;
        self.header_loaded = false;

        if (self.map) |*map| {
            map.destroy(self.io);
            self.map = null;
        }
        if (self.file) |file| {
            file.close(self.io);
            self.file = null;
        }
        self.bytes = "";
        self.opened = false;
    }

    fn loadHeader(self: *CsvReader) !void {
        if (self.header_loaded) return;

        try self.open();
        self.records = .{ .bytes = self.bytes };

        if (try self.records.next()) |record| {
            self.separator = detectSeparator(record.text) orelse .comma;

            var fields: Fields = .{
                .text = record.text,
                .separator = @backingInt(self.separator),
            };
            while (try fields.next()) |field| {
                try self.names.append(self.allocator, field.text);
            }
        }

        self.header_loaded = true;
    }

    fn open(self: *CsvReader) !void {
        if (self.opened) return;

        const file = try self.dir.openFile(self.io, self.path, .{});
        errdefer file.close(self.io);

        const length = try file.length(self.io);
        if (length > 0) {
            const map = try file.createMemoryMap(self.io, .{
                .len = length,
                .protection = .{ .read = true },
                .populate = false,
            });
            self.map = map;
            self.bytes = withoutBom(map.memory);
        }

        self.file = file;
        self.opened = true;
    }
};

fn withoutBom(bytes: []const u8) []const u8 {
    if (std.mem.startsWith(u8, bytes, bom)) {
        return bytes[bom.len..];
    }
    return bytes;
}

test "withoutBom" {
    const Case = struct {
        name: []const u8,
        bytes: []const u8,
        expected: []const u8,
    };

    const cases = [_]Case{
        .{
            .name = "ok_with_bom",
            .bytes = bom ++ "a,b",
            .expected = "a,b",
        },
        .{
            .name = "ok_without_bom",
            .bytes = "a,b",
            .expected = "a,b",
        },
        .{
            .name = "ok_bom_only",
            .bytes = bom,
            .expected = "",
        },
        .{
            .name = "ok_empty",
            .bytes = "",
            .expected = "",
        },
        .{
            .name = "ok_partial_bom_kept",
            .bytes = "\xEF\xBBa",
            .expected = "\xEF\xBBa",
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqualStrings(case.expected, withoutBom(case.bytes));
    }
}

test "open" {
    const Case = struct {
        name: []const u8,
        data: []const u8,
        expected: []const u8,
    };

    const cases = [_]Case{
        .{
            .name = "ok_with_bom",
            .data = bom ++ "a,b\n1,2\n",
            .expected = "a,b\n1,2\n",
        },
        .{
            .name = "ok_without_bom",
            .data = "a,b\n1,2\n",
            .expected = "a,b\n1,2\n",
        },
        .{
            .name = "ok_empty_file",
            .data = "",
            .expected = "",
        },
    };

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        try tmp.dir.writeFile(io, .{ .sub_path = "table.csv", .data = case.data });

        var reader = CsvReader.new(io, std.testing.allocator, tmp.dir, "table.csv");
        defer reader.close();

        try reader.open();
        try std.testing.expectEqualStrings(case.expected, reader.bytes);
    }
}

test "open fails on a missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var reader = CsvReader.new(std.testing.io, std.testing.allocator, tmp.dir, "missing.csv");
    defer reader.close();

    try std.testing.expectError(error.FileNotFound, reader.open());
    try std.testing.expect(!reader.opened);
}

test "open twice keeps the first mapping" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "table.csv", .data = "a,b\n" });

    var reader = CsvReader.new(io, std.testing.allocator, tmp.dir, "table.csv");
    defer reader.close();

    try reader.open();
    const first = reader.bytes;
    try reader.open();

    try std.testing.expectEqual(first.ptr, reader.bytes.ptr);
}

test "loadHeader" {
    const Case = struct {
        name: []const u8,
        data: []const u8,
        expected_names: []const []const u8,
        expected_separator: Separator,
    };

    const cases = [_]Case{
        .{
            .name = "ok_comma",
            .data = "name,city\nAlice,Paris\n",
            .expected_names = &.{ "name", "city" },
            .expected_separator = .comma,
        },
        .{
            .name = "ok_semicolon",
            .data = "name;city\nAlice;Paris\n",
            .expected_names = &.{ "name", "city" },
            .expected_separator = .semicolon,
        },
        .{
            .name = "ok_with_bom",
            .data = bom ++ "name;city\n",
            .expected_names = &.{ "name", "city" },
            .expected_separator = .semicolon,
        },
        .{
            .name = "ok_quoted_name",
            .data = "\"last, first\";city\n",
            .expected_names = &.{ "last, first", "city" },
            .expected_separator = .semicolon,
        },
        .{
            .name = "ok_single_column_defaults_to_comma",
            .data = "name\nAlice\n",
            .expected_names = &.{"name"},
            .expected_separator = .comma,
        },
        .{
            .name = "ok_empty_file",
            .data = "",
            .expected_names = &.{},
            .expected_separator = .comma,
        },
    };

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        try tmp.dir.writeFile(io, .{ .sub_path = "table.csv", .data = case.data });

        var reader = CsvReader.new(io, std.testing.allocator, tmp.dir, "table.csv");
        defer reader.close();

        try reader.loadHeader();

        try std.testing.expectEqual(case.expected_separator, reader.separator);
        try std.testing.expectEqual(case.expected_names.len, reader.names.items.len);
        for (case.expected_names, reader.names.items) |expected, actual| {
            try std.testing.expectEqualStrings(expected, actual);
        }
    }
}

test "loadHeader twice reads the header once" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "table.csv", .data = "a,b\n1,2\n" });

    var reader = CsvReader.new(io, std.testing.allocator, tmp.dir, "table.csv");
    defer reader.close();

    try reader.loadHeader();
    try reader.loadHeader();

    try std.testing.expectEqual(2, reader.names.items.len);
}
