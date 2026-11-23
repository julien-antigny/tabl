const std = @import("std");
const Row = @import("../../../core/table/row.zig").Row;
const Records = @import("records.zig").Records;
const Fields = @import("fields.zig").Fields;
const Field = @import("fields.zig").Field;
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
    name_bytes: std.ArrayList(u8) = .empty,
    header_loaded: bool = false,
    values: std.ArrayList([]const u8) = .empty,
    value_bytes: std.ArrayList(u8) = .empty,
    line: u64 = 0,

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
        self.name_bytes.deinit(self.allocator);
        self.name_bytes = .empty;
        self.header_loaded = false;
        self.values.deinit(self.allocator);
        self.values = .empty;
        self.value_bytes.deinit(self.allocator);
        self.value_bytes = .empty;

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
            self.line = record.line;
            self.separator = detectSeparator(record.text) orelse .comma;
            try self.split(record.text, &self.names, &self.name_bytes);
        }

        self.header_loaded = true;
    }

    fn nextRow(self: *CsvReader) !?Row {
        try self.loadHeader();

        const record = try self.records.next() orelse return null;
        self.line = record.line;

        try self.split(record.text, &self.values, &self.value_bytes);

        if (self.values.items.len != self.names.items.len) {
            return error.ColumnCountMismatch;
        }

        return .{ .values = self.values.items };
    }

    fn split(
        self: *CsvReader,
        text: []const u8,
        values: *std.ArrayList([]const u8),
        bytes: *std.ArrayList(u8),
    ) !void {
        values.clearRetainingCapacity();
        bytes.clearRetainingCapacity();
        try bytes.ensureTotalCapacity(self.allocator, text.len);

        var fields: Fields = .{
            .text = text,
            .separator = @backingInt(self.separator),
        };
        while (try fields.next()) |field| {
            try values.append(self.allocator, valueOf(field, bytes));
        }
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

fn valueOf(field: Field, bytes: *std.ArrayList(u8)) []const u8 {
    if (!field.has_escaped_quotes) return field.text;

    const start = bytes.items.len;
    var index: usize = 0;
    while (index < field.text.len) : (index += 1) {
        bytes.appendAssumeCapacity(field.text[index]);
        if (field.text[index] == '"') index += 1;
    }
    return bytes.items[start..];
}

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

test "nextRow" {
    const Case = struct {
        name: []const u8,
        data: []const u8,
        expected_names: []const []const u8,
        expected_rows: []const []const []const u8,
    };

    const cases = [_]Case{
        .{
            .name = "ok_two_rows",
            .data = "name,city\nAlice,Paris\nBob,Lyon\n",
            .expected_names = &.{ "name", "city" },
            .expected_rows = &.{
                &.{ "Alice", "Paris" },
                &.{ "Bob", "Lyon" },
            },
        },
        .{
            .name = "ok_quoted_value_with_separator",
            .data = "name;address\nAlice;\"1 rue A; Paris\"\n",
            .expected_names = &.{ "name", "address" },
            .expected_rows = &.{
                &.{ "Alice", "1 rue A; Paris" },
            },
        },
        .{
            .name = "ok_escaped_quotes_in_several_values",
            .data = "a,b,c\n\"x \"\"1\"\"\",plain,\"y \"\"2\"\"\"\n",
            .expected_names = &.{ "a", "b", "c" },
            .expected_rows = &.{
                &.{ "x \"1\"", "plain", "y \"2\"" },
            },
        },
        .{
            .name = "ok_escaped_quotes_in_header",
            .data = "\"say \"\"hi\"\"\",b\n1,2\n",
            .expected_names = &.{ "say \"hi\"", "b" },
            .expected_rows = &.{
                &.{ "1", "2" },
            },
        },
        .{
            .name = "ok_empty_values",
            .data = "a,b,c\n,,\n",
            .expected_names = &.{ "a", "b", "c" },
            .expected_rows = &.{
                &.{ "", "", "" },
            },
        },
        .{
            .name = "ok_header_only",
            .data = "a,b\n",
            .expected_names = &.{ "a", "b" },
            .expected_rows = &.{},
        },
        .{
            .name = "ok_empty_file",
            .data = "",
            .expected_names = &.{},
            .expected_rows = &.{},
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

        for (case.expected_rows) |expected| {
            const row = (try reader.nextRow()).?;
            try std.testing.expectEqual(expected.len, row.values.len);
            for (expected, row.values) |expected_value, value| {
                try std.testing.expectEqualStrings(expected_value, value);
            }
        }
        try std.testing.expect(try reader.nextRow() == null);

        try std.testing.expectEqual(case.expected_names.len, reader.names.items.len);
        for (case.expected_names, reader.names.items) |expected, name| {
            try std.testing.expectEqualStrings(expected, name);
        }
    }
}

test "nextRow fails on a wrong number of values" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "table.csv", .data = "a,b\n1,2\n1,2,3\n" });

    var reader = CsvReader.new(io, std.testing.allocator, tmp.dir, "table.csv");
    defer reader.close();

    _ = try reader.nextRow();
    try std.testing.expectError(error.ColumnCountMismatch, reader.nextRow());
    try std.testing.expectEqual(3, reader.line);
}
