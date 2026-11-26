const std = @import("std");
const Value = @import("../value.zig").Value;
const ColumnType = @import("type.zig").ColumnType;
const DecimalMark = @import("type.zig").DecimalMark;
const parseInteger = @import("parse_number.zig").parseInteger;
const parseDecimal = @import("parse_number.zig").parseDecimal;
const parseBoolean = @import("parse_boolean.zig").parseBoolean;
const parseDate = @import("parse_date.zig").parseDate;

/// Turns a value read from the source into a value of its column type.
///
/// Returns null when the text does not fit `column_type`: possible when
/// inference has seen only a sample of the values.
///
/// `value` is `.empty` or `.text`, any other value is a programming error.
pub fn convert(value: Value, column_type: ColumnType, decimal_mark: DecimalMark) ?Value {
    const text = switch (value) {
        .empty => return .empty,
        .text => |text| text,
        .integer, .decimal, .boolean, .date => unreachable,
    };

    return switch (column_type) {
        .integer => .{ .integer = parseInteger(text) orelse return null },
        .decimal => .{ .decimal = parseDecimal(text, decimal_mark) orelse return null },
        .boolean => .{ .boolean = parseBoolean(text) orelse return null },
        .date => |format| .{ .date = parseDate(text, format) orelse return null },
        .text => value,
    };
}

test "convert" {
    const Case = struct {
        name: []const u8,
        value: Value,
        column_type: ColumnType,
        decimal_mark: DecimalMark = .point,
        expected: ?Value,
    };

    const cases = [_]Case{
        .{
            .name = "ok_empty",
            .value = .empty,
            .column_type = .integer,
            .expected = .empty,
        },
        .{
            .name = "ok_integer",
            .value = .{ .text = "-42" },
            .column_type = .integer,
            .expected = .{ .integer = -42 },
        },
        .{
            .name = "ok_decimal",
            .value = .{ .text = "1.5" },
            .column_type = .decimal,
            .expected = .{ .decimal = 1.5 },
        },
        .{
            .name = "ok_comma_decimal",
            .value = .{ .text = "1,5" },
            .column_type = .decimal,
            .decimal_mark = .comma,
            .expected = .{ .decimal = 1.5 },
        },
        .{
            .name = "ok_integer_in_decimal_column",
            .value = .{ .text = "10" },
            .column_type = .decimal,
            .expected = .{ .decimal = 10 },
        },
        .{
            .name = "ok_boolean",
            .value = .{ .text = "TRUE" },
            .column_type = .boolean,
            .expected = .{ .boolean = true },
        },
        .{
            .name = "ok_date",
            .value = .{ .text = "02/01/1970" },
            .column_type = .{ .date = .day_month_year_slash },
            .expected = .{ .date = 1 },
        },
        .{
            .name = "ok_text",
            .value = .{ .text = "Paris" },
            .column_type = .text,
            .expected = .{ .text = "Paris" },
        },
        .{
            .name = "error_text_in_integer_column",
            .value = .{ .text = "N/A" },
            .column_type = .integer,
            .expected = null,
        },
        .{
            .name = "error_point_in_comma_column",
            .value = .{ .text = "1.5" },
            .column_type = .decimal,
            .decimal_mark = .comma,
            .expected = null,
        },
        .{
            .name = "ok_number_in_text_column",
            .value = .{ .text = "12" },
            .column_type = .text,
            .expected = .{ .text = "12" },
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqualDeep(case.expected, convert(case.value, case.column_type, case.decimal_mark));
    }
}
