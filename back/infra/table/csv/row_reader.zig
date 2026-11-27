const std = @import("std");
const Diagnostics = @import("../../../core/diagnostic.zig").Diagnostics;
const Row = @import("../../../core/table/row.zig").Row;
const RowReader = @import("../../../core/table/row_reader.zig").RowReader;
const TableError = @import("../../../core/table/errors.zig").TableError;
const Value = @import("../../../core/table/value.zig").Value;
const Records = @import("records.zig").Records;
const Record = @import("records.zig").Record;
const Fields = @import("fields.zig").Fields;
const Field = @import("fields.zig").Field;
const Separator = @import("separator.zig").Separator;
const fail = @import("errors.zig").fail;

/// Reads the rows of one part of a CSV file.
///
/// The header is read before, by the `CsvReader` that creates the row
/// reader: the row reader only shares its names and its separator.
///
/// Each row reader is read by its own thread, and changes its fields on
/// every row: it starts on its own cache line, so that two row readers side
/// by side never make two cores write to the same one.
pub const CsvRowReader = struct {
    allocator: std.mem.Allocator align(std.atomic.cache_line),
    path: []const u8,
    names: []const []const u8,
    separator: Separator,
    records: Records,
    values: std.ArrayList(Value) = .empty,
    value_bytes: std.ArrayList(u8) = .empty,
    line: u64 = 0,

    /// `records` is positioned on the first row of the part,
    /// and its bytes end with the last row.
    pub fn new(
        allocator: std.mem.Allocator,
        path: []const u8,
        names: []const []const u8,
        separator: Separator,
        records: Records,
    ) CsvRowReader {
        return .{
            .allocator = allocator,
            .path = path,
            .names = names,
            .separator = separator,
            .records = records,
        };
    }

    pub fn deinit(self: *CsvRowReader) void {
        self.values.deinit(self.allocator);
        self.values = .empty;
        self.value_bytes.deinit(self.allocator);
        self.value_bytes = .empty;
    }

    pub fn rowReader(self: *CsvRowReader) RowReader {
        return .{
            .ptr = self,
            .vtable = &.{ .next = next },
        };
    }

    fn next(ptr: *anyopaque, diagnostics: *Diagnostics) TableError!?Row {
        const self: *CsvRowReader = @ptrCast(@alignCast(ptr));
        return self.nextRow() catch |err| fail(
            err,
            self.path,
            self.line,
            .{ .expected = self.names.len, .found = self.values.items.len },
            diagnostics,
        );
    }

    fn nextRow(self: *CsvRowReader) !?Row {
        const record = try self.nextRecord() orelse return null;

        try self.splitValues(record.text);

        if (self.values.items.len != self.names.len) {
            return error.ColumnCountMismatch;
        }

        return .{ .values = self.values.items };
    }

    fn nextRecord(self: *CsvRowReader) !?Record {
        const record = self.records.next() catch |err| {
            self.line = self.records.line;
            return err;
        };
        if (record) |found| self.line = found.line;
        return record;
    }

    fn splitValues(self: *CsvRowReader, text: []const u8) !void {
        self.values.clearRetainingCapacity();
        self.value_bytes.clearRetainingCapacity();
        try self.value_bytes.ensureTotalCapacity(self.allocator, text.len);

        var fields: Fields = .{
            .text = text,
            .separator = @backingInt(self.separator),
        };
        while (try fields.next()) |field| {
            try self.values.append(
                self.allocator,
                valueOf(field, &self.value_bytes),
            );
        }
    }
};

/// The text of a field, with `""` turned into `"`: copied into `bytes`
/// only when needed, which must have room for it.
pub fn textOf(field: Field, bytes: *std.ArrayList(u8)) []const u8 {
    if (!field.has_escaped_quotes) return field.text;

    const start = bytes.items.len;
    var index: usize = 0;
    while (index < field.text.len) : (index += 1) {
        bytes.appendAssumeCapacity(field.text[index]);
        if (field.text[index] == '"') index += 1;
    }
    return bytes.items[start..];
}

fn valueOf(field: Field, bytes: *std.ArrayList(u8)) Value {
    if (!field.quoted and field.text.len == 0) return .empty;
    return .{ .text = textOf(field, bytes) };
}

fn rowReaderOf(names: []const []const u8, bytes: []const u8) CsvRowReader {
    return .new(
        std.testing.allocator,
        "table.csv",
        names,
        .comma,
        .{ .bytes = bytes },
    );
}

test "next" {
    const Case = struct {
        name: []const u8,
        bytes: []const u8,
        expected_rows: []const []const Value,
    };

    const cases = [_]Case{
        .{
            .name = "ok_two_rows",
            .bytes = "Alice,Paris\nBob,Lyon\n",
            .expected_rows = &.{
                &.{ .{ .text = "Alice" }, .{ .text = "Paris" } },
                &.{ .{ .text = "Bob" }, .{ .text = "Lyon" } },
            },
        },
        .{
            .name = "ok_escaped_quotes_in_several_values",
            .bytes = "\"x \"\"1\"\"\",\"y \"\"2\"\"\"\n",
            .expected_rows = &.{
                &.{ .{ .text = "x \"1\"" }, .{ .text = "y \"2\"" } },
            },
        },
        .{
            .name = "ok_empty_value_and_empty_text",
            .bytes = ",\"\"\n",
            .expected_rows = &.{
                &.{ .empty, .{ .text = "" } },
            },
        },
        .{
            .name = "ok_no_rows",
            .bytes = "",
            .expected_rows = &.{},
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var row_reader = rowReaderOf(&.{ "a", "b" }, case.bytes);
        defer row_reader.deinit();
        var diagnostics: Diagnostics = .{};

        for (case.expected_rows) |expected| {
            const row = (try row_reader.rowReader().next(&diagnostics)).?;
            try std.testing.expectEqualDeep(expected, row.values);
        }
        try std.testing.expectEqual(null, try row_reader.rowReader().next(&diagnostics));
    }
}

test "next fails on a wrong number of values" {
    var row_reader = rowReaderOf(&.{ "a", "b" }, "1,2\n1,2,3\n");
    defer row_reader.deinit();
    var diagnostics: Diagnostics = .{};

    _ = try row_reader.rowReader().next(&diagnostics);
    try std.testing.expectError(
        error.Malformed,
        row_reader.rowReader().next(&diagnostics),
    );
    try std.testing.expectEqualStrings(
        "expected 2 values, found 3",
        diagnostics.last().?.message,
    );
    try std.testing.expectEqual(2, row_reader.line);
}
