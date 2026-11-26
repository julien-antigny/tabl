const std = @import("std");
const Value = @import("../value.zig").Value;
const ColumnType = @import("type.zig").ColumnType;
const parseInteger = @import("parse_number.zig").parseInteger;
const parseDecimal = @import("parse_number.zig").parseDecimal;
const parseBoolean = @import("parse_boolean.zig").parseBoolean;
const parseDate = @import("parse_date.zig").parseDate;

/// Turns a value read from the source into a value of its column type.
///
/// `value` is `.empty` or `.text`, and its text fits `column_type`:
/// inference has seen it. Any other call is a programming error.
pub fn convert(value: Value, column_type: ColumnType) Value {
    const text = switch (value) {
        .empty => return .empty,
        .text => |text| text,
        .integer, .decimal, .boolean, .date => unreachable,
    };

    return switch (column_type) {
        .integer => .{ .integer = parseInteger(text).? },
        .decimal => .{ .decimal = parseDecimal(text).? },
        .boolean => .{ .boolean = parseBoolean(text).? },
        .date => |format| .{ .date = parseDate(text, format).? },
        .text => value,
    };
}

test "convert" {
    const Case = struct {
        name: []const u8,
        value: Value,
        column_type: ColumnType,
        expected: Value,
    };

    const cases = [_]Case{
        .{ .name = "ok_empty", .value = .empty, .column_type = .integer, .expected = .empty },
        .{ .name = "ok_integer", .value = .{ .text = "-42" }, .column_type = .integer, .expected = .{ .integer = -42 } },
        .{ .name = "ok_decimal", .value = .{ .text = "1.5" }, .column_type = .decimal, .expected = .{ .decimal = 1.5 } },
        .{ .name = "ok_integer_in_decimal_column", .value = .{ .text = "10" }, .column_type = .decimal, .expected = .{ .decimal = 10 } },
        .{ .name = "ok_boolean", .value = .{ .text = "TRUE" }, .column_type = .boolean, .expected = .{ .boolean = true } },
        .{ .name = "ok_date", .value = .{ .text = "02/01/1970" }, .column_type = .{ .date = .day_month_year_slash }, .expected = .{ .date = 1 } },
        .{ .name = "ok_text", .value = .{ .text = "Paris" }, .column_type = .text, .expected = .{ .text = "Paris" } },
        .{ .name = "ok_number_in_text_column", .value = .{ .text = "12" }, .column_type = .text, .expected = .{ .text = "12" } },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqualDeep(case.expected, convert(case.value, case.column_type));
    }
}
