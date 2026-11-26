const std = @import("std");
const CacheError = @import("errors.zig").CacheError;
const Type = @import("../../../core/table/type/type.zig").Type;
const Value = @import("../../../core/table/value.zig").Value;
const widthOf = @import("values_file.zig").widthOf;

/// `N.values` read back: one fixed-width value per row, little-endian.
pub const ValuesColumn = struct {
    bytes: []const u8,
    type: Type,

    /// `column_type` is any type but `.text`.
    pub fn new(bytes: []const u8, column_type: Type, rows: u32) CacheError!ValuesColumn {
        const width = widthOf(column_type).?;
        if (bytes.len != @as(u64, rows) * width) {
            return CacheError.SizeMismatch;
        }
        return .{ .bytes = bytes, .type = column_type };
    }

    /// The value of a row that is not empty. A boolean byte other than 0
    /// reads as true.
    pub fn value(self: ValuesColumn, row: u32) Value {
        return switch (self.type) {
            .integer => .{ .integer = std.mem.readInt(i64, self.slot(8, row), .little) },
            .decimal => .{ .decimal = @bitCast(std.mem.readInt(u64, self.slot(8, row), .little)) },
            .date => .{ .date = std.mem.readInt(i32, self.slot(4, row), .little) },
            .boolean => .{ .boolean = self.bytes[row] != 0 },
            .text => unreachable,
        };
    }

    fn slot(self: ValuesColumn, comptime width: usize, row: u32) *const [width]u8 {
        return self.bytes[@as(usize, row) * width ..][0..width];
    }
};

test "value" {
    const Case = struct {
        name: []const u8,
        bytes: []const u8,
        type: Type,
        expected: []const Value,
    };

    const cases = [_]Case{
        .{
            .name = "ok_integer",
            .bytes = &.{ 0x1F, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
            .type = .integer,
            .expected = &.{ .{ .integer = 31 }, .{ .integer = -1 } },
        },
        .{
            .name = "ok_decimal",
            .bytes = &.{ 0, 0, 0, 0, 0, 0, 0xF8, 0x3F },
            .type = .decimal,
            .expected = &.{.{ .decimal = 1.5 }},
        },
        .{
            .name = "ok_date",
            .bytes = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x55, 0x4D, 0, 0 },
            .type = .date,
            .expected = &.{ .{ .date = -1 }, .{ .date = 19797 } },
        },
        .{
            .name = "ok_boolean",
            .bytes = &.{ 1, 0, 7 },
            .type = .boolean,
            .expected = &.{ .{ .boolean = true }, .{ .boolean = false }, .{ .boolean = true } },
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        const column = try ValuesColumn.new(case.bytes, case.type, @intCast(case.expected.len));
        for (case.expected, 0..) |expected, row| {
            try std.testing.expectEqualDeep(expected, column.value(@intCast(row)));
        }
    }
}

test "new fails on a wrong size" {
    const Case = struct {
        name: []const u8,
        bytes: []const u8,
        type: Type,
        rows: u32,
    };

    const cases = [_]Case{
        .{ .name = "error_integer_too_short", .bytes = &.{ 0, 0, 0, 0 }, .type = .integer, .rows = 1 },
        .{ .name = "error_date_too_long", .bytes = &.{ 0, 0, 0, 0, 0 }, .type = .date, .rows = 1 },
        .{ .name = "error_boolean_rows", .bytes = &.{ 1, 0 }, .type = .boolean, .rows = 3 },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectError(CacheError.SizeMismatch, ValuesColumn.new(case.bytes, case.type, case.rows));
    }
}
