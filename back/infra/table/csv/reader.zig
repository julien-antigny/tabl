const std = @import("std");
const Diagnostics = @import("../../../core/diagnostic.zig").Diagnostics;
const Header = @import("../../../core/table/header.zig").Header;
const Reader = @import("../../../core/table/reader.zig").Reader;
const RowReader = @import("../../../core/table/row_reader.zig").RowReader;
const TableError = @import("../../../core/table/errors.zig").TableError;
const Records = @import("records.zig").Records;
const Record = @import("records.zig").Record;
const Fields = @import("fields.zig").Fields;
const Separator = @import("separator.zig").Separator;
const detectSeparator = @import("separator.zig").detect;
const CsvRowReader = @import("row_reader.zig").CsvRowReader;
const textOf = @import("row_reader.zig").textOf;
const errors = @import("errors.zig");
const Value = @import("../../../core/table/value.zig").Value;

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
    separator: Separator = .comma,
    names: std.ArrayList([]const u8) = .empty,
    name_bytes: std.ArrayList(u8) = .empty,
    header_loaded: bool = false,
    /// The line of the header, for its failures.
    line: u64 = 0,
    /// Positioned on the first row, once the header is loaded.
    first_row: Records = .{ .bytes = "" },
    csv_row_readers: []CsvRowReader = &.{},
    row_readers: []RowReader = &.{},

    pub fn new(
        io: std.Io,
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        path: []const u8,
    ) CsvReader {
        return .{
            .io = io,
            .allocator = allocator,
            .dir = dir,
            .path = path,
        };
    }

    pub fn close(self: *CsvReader) void {
        self.freeRowReaders();
        self.header_loaded = false;
        self.names.deinit(self.allocator);
        self.names = .empty;
        self.name_bytes.deinit(self.allocator);
        self.name_bytes = .empty;

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

    pub fn reader(self: *CsvReader) Reader {
        return .{
            .ptr = self,
            .vtable = &.{
                .header = header,
                .rowReaders = rowReaders,
            },
        };
    }

    fn header(ptr: *anyopaque, diagnostics: *Diagnostics) TableError!Header {
        const self: *CsvReader = @ptrCast(@alignCast(ptr));
        self.loadHeader() catch |err| return self.fail(err, diagnostics);
        return .{ .names = self.names.items };
    }

    fn rowReaders(
        ptr: *anyopaque,
        count: usize,
        diagnostics: *Diagnostics,
    ) TableError![]const RowReader {
        const self: *CsvReader = @ptrCast(@alignCast(ptr));
        self.createRowReaders(count) catch |err| return self.fail(err, diagnostics);
        return self.row_readers;
    }

    fn fail(
        self: *CsvReader,
        err: anyerror,
        diagnostics: *Diagnostics,
    ) TableError {
        return errors.fail(err, self.path, self.line, .{}, diagnostics);
    }

    fn loadHeader(self: *CsvReader) !void {
        if (self.header_loaded) return;

        try self.open();
        var records: Records = .{ .bytes = self.bytes };

        if (try self.nextRecord(&records)) |record| {
            self.separator = detectSeparator(record.text) orelse .comma;
            try self.splitNames(record.text);
        }

        self.first_row = records;
        self.header_loaded = true;
    }

    fn nextRecord(self: *CsvReader, records: *Records) !?Record {
        const record = records.next() catch |err| {
            self.line = records.line;
            return err;
        };
        if (record) |found| self.line = found.line;
        return record;
    }

    fn splitNames(self: *CsvReader, text: []const u8) !void {
        self.names.clearRetainingCapacity();
        self.name_bytes.clearRetainingCapacity();
        try self.name_bytes.ensureTotalCapacity(self.allocator, text.len);

        var fields: Fields = .{
            .text = text,
            .separator = @backingInt(self.separator),
        };
        while (try fields.next()) |field| {
            try self.names.append(
                self.allocator,
                textOf(field, &self.name_bytes),
            );
        }
    }

    /// Cuts the rows into at most `count` parts, each starting on a row,
    /// and creates a row reader for each.
    fn createRowReaders(self: *CsvReader, count: usize) !void {
        std.debug.assert(count > 0);
        try self.loadHeader();
        self.freeRowReaders();

        const starts = try self.allocator.alloc(RowStart, count);
        defer self.allocator.free(starts);
        const first: RowStart = .{
            .position = self.first_row.position,
            .line = self.first_row.line,
        };
        const found = rowStarts(self.bytes, first, starts);

        const csv_row_readers = try self.allocator.alloc(CsvRowReader, found);
        errdefer self.allocator.free(csv_row_readers);
        const row_readers = try self.allocator.alloc(RowReader, found);

        for (
            csv_row_readers,
            row_readers,
            starts[0..found],
            0..,
        ) |*csv_row_reader, *row_reader, start, index| {
            const end = if (index + 1 < found) starts[index + 1].position else self.bytes.len;
            csv_row_reader.* = .new(
                self.allocator,
                self.path,
                self.names.items,
                self.separator,
                .{
                    .bytes = self.bytes[0..end],
                    .position = start.position,
                    .line = start.line,
                },
            );
            row_reader.* = csv_row_reader.rowReader();
        }

        self.csv_row_readers = csv_row_readers;
        self.row_readers = row_readers;
    }

    fn freeRowReaders(self: *CsvReader) void {
        for (self.csv_row_readers) |*csv_row_reader| csv_row_reader.deinit();
        self.allocator.free(self.csv_row_readers);
        self.csv_row_readers = &.{};
        self.allocator.free(self.row_readers);
        self.row_readers = &.{};
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

/// Where a row starts in the bytes, and its line.
const RowStart = struct {
    position: usize,
    line: u64,
};

/// Fills `starts` with the start of at most `starts.len` parts of about the
/// same size, `first` being the first row. Returns how many were found.
///
/// A position is inside quotes when an odd number of `"` comes before it,
/// from `first` which is outside: the `"` and `\n` of each part are counted
/// in a single loop, then a part starts after the next `\n` outside quotes.
fn rowStarts(bytes: []const u8, first: RowStart, starts: []RowStart) usize {
    starts[0] = first;
    var found: usize = 1;
    var position = first.position;
    var line = first.line;
    const size = bytes.len - first.position;

    for (1..starts.len) |index| {
        const target = first.position + size * index / starts.len;
        if (target <= position) continue;

        // Counted up to the byte before the target: when that byte ends a row,
        // the part starts right on the target.
        var quotes: usize = 0;
        var line_ends: u64 = 0;
        for (bytes[position .. target - 1]) |byte| {
            quotes += @intFromBool(byte == '"');
            line_ends += @intFromBool(byte == '\n');
        }
        var in_quotes = quotes % 2 == 1;
        line += line_ends;
        position = target - 1;

        while (position < bytes.len) : (position += 1) {
            switch (bytes[position]) {
                '"' => in_quotes = !in_quotes,
                '\n' => {
                    line += 1;
                    if (!in_quotes) break;
                },
                else => {},
            }
        }
        position += 1;
        if (position >= bytes.len) break;

        starts[found] = .{ .position = position, .line = line };
        found += 1;
    }
    return found;
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

test "rowReaders reads every row" {
    const Case = struct {
        name: []const u8,
        data: []const u8,
        expected_names: []const []const u8,
        expected_rows: []const []const Value,
    };

    const cases = [_]Case{
        .{
            .name = "ok_two_rows",
            .data = "name,city\nAlice,Paris\nBob,Lyon\n",
            .expected_names = &.{ "name", "city" },
            .expected_rows = &.{
                &.{ .{ .text = "Alice" }, .{ .text = "Paris" } },
                &.{ .{ .text = "Bob" }, .{ .text = "Lyon" } },
            },
        },
        .{
            .name = "ok_quoted_value_with_separator",
            .data = "name;address\nAlice;\"1 rue A; Paris\"\n",
            .expected_names = &.{ "name", "address" },
            .expected_rows = &.{
                &.{ .{ .text = "Alice" }, .{ .text = "1 rue A; Paris" } },
            },
        },
        .{
            .name = "ok_escaped_quotes_in_several_values",
            .data = "a,b,c\n\"x \"\"1\"\"\",plain,\"y \"\"2\"\"\"\n",
            .expected_names = &.{ "a", "b", "c" },
            .expected_rows = &.{
                &.{ .{ .text = "x \"1\"" }, .{ .text = "plain" }, .{ .text = "y \"2\"" } },
            },
        },
        .{
            .name = "ok_escaped_quotes_in_header",
            .data = "\"say \"\"hi\"\"\",b\n1,2\n",
            .expected_names = &.{ "say \"hi\"", "b" },
            .expected_rows = &.{
                &.{ .{ .text = "1" }, .{ .text = "2" } },
            },
        },
        .{
            .name = "ok_empty_values",
            .data = "a,b,c\n,,\n",
            .expected_names = &.{ "a", "b", "c" },
            .expected_rows = &.{
                &.{ .empty, .empty, .empty },
            },
        },
        .{
            .name = "ok_empty_value_and_empty_text",
            .data = "a,b,c\n,\"\",x\n",
            .expected_names = &.{ "a", "b", "c" },
            .expected_rows = &.{
                &.{ .empty, .{ .text = "" }, .{ .text = "x" } },
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

        var csv = CsvReader.new(io, std.testing.allocator, tmp.dir, "table.csv");
        defer csv.close();
        var diagnostics: Diagnostics = .{};
        const row_reader = (try csv.reader().rowReaders(1, &diagnostics))[0];

        for (case.expected_rows) |expected| {
            const row = (try row_reader.next(&diagnostics)).?;
            try std.testing.expectEqualDeep(expected, row.values);
        }
        try std.testing.expectEqual(null, try row_reader.next(&diagnostics));

        try std.testing.expectEqual(case.expected_names.len, csv.names.items.len);
        for (case.expected_names, csv.names.items) |expected, name| {
            try std.testing.expectEqualStrings(expected, name);
        }
    }
}

test "rowReaders cuts on whole rows" {
    const Case = struct {
        name: []const u8,
        data: []const u8,
        count: usize,
        /// The first value of each row, row reader by row reader.
        expected_parts: []const []const []const u8,
        /// The line of the first row of each row reader, 0 when it has none.
        expected_lines: []const u64,
    };

    const cases = [_]Case{
        .{
            .name = "ok_one_part",
            .data = "a\n1\n2\n",
            .count = 1,
            .expected_parts = &.{&.{ "1", "2" }},
            .expected_lines = &.{2},
        },
        .{
            .name = "ok_parts_of_same_size",
            .data = "a\n1\n2\n3\n4\n",
            .count = 2,
            .expected_parts = &.{ &.{ "1", "2" }, &.{ "3", "4" } },
            .expected_lines = &.{ 2, 4 },
        },
        .{
            .name = "ok_line_end_in_quotes_stays_in_its_row",
            .data = "a\n\"x\ny\"\n2\n",
            .count = 2,
            .expected_parts = &.{ &.{"x\ny"}, &.{"2"} },
            .expected_lines = &.{ 2, 4 },
        },
        .{
            .name = "ok_escaped_quotes_keep_the_count_even",
            .data = "a\n\"x\"\"\"\n2\n3\n",
            .count = 2,
            .expected_parts = &.{ &.{"x\""}, &.{ "2", "3" } },
            .expected_lines = &.{ 2, 3 },
        },
        .{
            .name = "ok_fewer_rows_than_parts",
            .data = "a\n1\n",
            .count = 4,
            .expected_parts = &.{&.{"1"}},
            .expected_lines = &.{2},
        },
        .{
            .name = "ok_without_final_line_end",
            .data = "a\n1\n2\n3",
            .count = 2,
            .expected_parts = &.{ &.{"1"}, &.{ "2", "3" } },
            .expected_lines = &.{ 2, 3 },
        },
        .{
            .name = "ok_header_only",
            .data = "a\n",
            .count = 3,
            .expected_parts = &.{&.{}},
            .expected_lines = &.{0},
        },
        .{
            .name = "ok_empty_file",
            .data = "",
            .count = 2,
            .expected_parts = &.{&.{}},
            .expected_lines = &.{0},
        },
    };

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        try tmp.dir.writeFile(io, .{ .sub_path = "table.csv", .data = case.data });

        var csv = CsvReader.new(io, std.testing.allocator, tmp.dir, "table.csv");
        defer csv.close();
        var diagnostics: Diagnostics = .{};

        const row_readers = try csv.reader().rowReaders(case.count, &diagnostics);

        try std.testing.expectEqual(case.expected_parts.len, row_readers.len);
        for (
            row_readers,
            case.expected_parts,
            case.expected_lines,
            csv.csv_row_readers,
        ) |row_reader, expected_rows, expected_line, csv_row_reader| {
            for (expected_rows, 0..) |expected, index| {
                const row = (try row_reader.next(&diagnostics)).?;
                try std.testing.expectEqualStrings(expected, row.values[0].text);
                if (index == 0) try std.testing.expectEqual(
                    expected_line,
                    csv_row_reader.line,
                );
            }
            try std.testing.expectEqual(null, try row_reader.next(&diagnostics));
        }
    }
}

test "rowReaders again reads the rows again" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "table.csv", .data = "a\n1\n2\n" });

    var csv = CsvReader.new(io, std.testing.allocator, tmp.dir, "table.csv");
    defer csv.close();
    var diagnostics: Diagnostics = .{};

    const first = (try csv.reader().rowReaders(1, &diagnostics))[0];
    _ = try first.next(&diagnostics);
    _ = try first.next(&diagnostics);

    const row_readers = try csv.reader().rowReaders(2, &diagnostics);
    try std.testing.expectEqual(2, row_readers.len);
    try std.testing.expectEqualStrings(
        "1",
        (try row_readers[0].next(&diagnostics)).?.values[0].text,
    );
    try std.testing.expectEqualStrings(
        "2",
        (try row_readers[1].next(&diagnostics)).?.values[0].text,
    );
}

test "failures are translated with their location" {
    const Case = struct {
        name: []const u8,
        path: []const u8,
        data: ?[]const u8,
        expected_error: TableError,
        expected_kind: anyerror,
        expected_message: []const u8,
        expected_line: ?u64,
    };

    const cases = [_]Case{
        .{
            .name = "err_missing_file",
            .path = "missing.csv",
            .data = null,
            .expected_error = error.NotFound,
            .expected_kind = error.FileNotFound,
            .expected_message = "file not found",
            .expected_line = null,
        },
        .{
            .name = "err_unterminated_quote",
            .path = "quote.csv",
            .data = "a,b\n1,2\n\"3,4\n5,6\n",
            .expected_error = error.Malformed,
            .expected_kind = error.UnterminatedQuote,
            .expected_message = "unterminated quote",
            .expected_line = 3,
        },
        .{
            .name = "err_char_after_quote",
            .path = "after.csv",
            .data = "a,b\n\"1\"x,2\n",
            .expected_error = error.Malformed,
            .expected_kind = error.UnexpectedCharAfterQuote,
            .expected_message = "unexpected character after a closing quote",
            .expected_line = 2,
        },
        .{
            .name = "err_column_count",
            .path = "count.csv",
            .data = "a,b\n1,2\n1,2,3\n",
            .expected_error = error.Malformed,
            .expected_kind = error.ColumnCountMismatch,
            .expected_message = "expected 2 values, found 3",
            .expected_line = 3,
        },
    };

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        if (case.data) |data| {
            try tmp.dir.writeFile(io, .{ .sub_path = case.path, .data = data });
        }

        var csv = CsvReader.new(io, std.testing.allocator, tmp.dir, case.path);
        defer csv.close();
        var diagnostics: Diagnostics = .{};

        const result = blk: {
            const row_readers = csv.reader().rowReaders(1, &diagnostics) catch |err| break :blk err;
            while (true) {
                const row = row_readers[0].next(&diagnostics) catch |err| break :blk err;
                if (row == null) return error.TestExpectedError;
            }
        };

        try std.testing.expectEqual(case.expected_error, result);
        try std.testing.expectEqual(1, diagnostics.size);
        const diagnostic = diagnostics.last().?;
        try std.testing.expectEqual(.infra, diagnostic.layer);
        try std.testing.expectEqual(case.expected_kind, diagnostic.kind);
        try std.testing.expectEqualStrings(case.expected_message, diagnostic.message);
        try std.testing.expectEqualStrings(case.path, diagnostic.location.?.path);
        try std.testing.expectEqual(case.expected_line, diagnostic.location.?.line);
    }
}
