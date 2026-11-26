const std = @import("std");
const DecimalMark = @import("type.zig").DecimalMark;

/// Reads an integer: an optional sign, then digits without a leading zero.
/// Returns null when the text is not an integer or does not fit in an `i64`.
pub fn parseInteger(text: []const u8) ?i64 {
    const negative = text.len > 0 and text[0] == '-';
    const has_sign = negative or (text.len > 0 and text[0] == '+');
    const digits = if (has_sign) text[1..] else text;

    if (digits.len == 0) return null;
    if (digits[0] == '0' and digits.len > 1) return null;

    var value: i64 = 0;
    for (digits) |char| {
        if (!std.ascii.isDigit(char)) return null;
        const digit: i64 = char - '0';
        value = std.math.mul(i64, value, 10) catch return null;
        value = if (negative)
            std.math.sub(i64, value, digit) catch return null
        else
            std.math.add(i64, value, digit) catch return null;
    }
    return value;
}

/// The longest decimal written with a comma: it is copied on the stack
/// to replace the comma with a point.
const max_comma_decimal_len = 64;

/// Reads a decimal: an integer, then optionally the mark followed by digits,
/// then optionally `e` or `E` followed by an integer.
/// Returns null when the text is not a decimal or is too large for an `f64`.
/// With a comma, a text longer than 64 characters is not a decimal.
pub fn parseDecimal(text: []const u8, mark: DecimalMark) ?f64 {
    const mark_char: u8 = switch (mark) {
        .point => '.',
        .comma => ',',
    };
    if (!isDecimalText(text, mark_char)) return null;
    const value = switch (mark) {
        .point => std.fmt.parseFloat(f64, text) catch return null,
        .comma => parseCommaDecimal(text) orelse return null,
    };
    if (std.math.isInf(value)) return null;
    return value;
}

/// Replaces the comma with a point, then reads the text as a float.
fn parseCommaDecimal(text: []const u8) ?f64 {
    if (text.len > max_comma_decimal_len) return null;

    var buffer: [max_comma_decimal_len]u8 = undefined;
    const copy = buffer[0..text.len];

    @memcpy(copy, text);

    std.mem.replaceScalar(u8, copy, ',', '.');

    return std.fmt.parseFloat(f64, copy) catch null;
}

fn isDecimalText(text: []const u8, mark: u8) bool {
    var before_exponent = text;
    if (std.mem.indexOfAny(u8, text, "eE")) |exponent_start| {
        if (!isIntegerText(text[exponent_start + 1 ..])) return false;
        before_exponent = text[0..exponent_start];
    }

    if (std.mem.indexOfScalar(u8, before_exponent, mark)) |mark_index| {
        const fraction = before_exponent[mark_index + 1 ..];

        return isIntegerText(before_exponent[0..mark_index]) and
            fraction.len > 0 and
            isDigits(fraction);
    }

    return isIntegerText(before_exponent);
}

fn isIntegerText(text: []const u8) bool {
    const has_sign = text.len > 0 and (text[0] == '+' or text[0] == '-');
    const digits = if (has_sign) text[1..] else text;

    if (digits.len == 0) return false;
    if (digits[0] == '0' and digits.len > 1) return false;

    return isDigits(digits);
}

fn isDigits(text: []const u8) bool {
    for (text) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }
    return true;
}

test "parseInteger" {
    const Case = struct {
        name: []const u8,
        text: []const u8,
        expected: ?i64,
    };

    const cases = [_]Case{
        .{
            .name = "ok_digits",
            .text = "123",
            .expected = 123,
        },
        .{
            .name = "ok_zero",
            .text = "0",
            .expected = 0,
        },
        .{
            .name = "ok_minus",
            .text = "-42",
            .expected = -42,
        },
        .{
            .name = "ok_plus",
            .text = "+7",
            .expected = 7,
        },
        .{
            .name = "ok_largest",
            .text = "9223372036854775807",
            .expected = std.math.maxInt(i64),
        },
        .{
            .name = "ok_smallest",
            .text = "-9223372036854775808",
            .expected = std.math.minInt(i64),
        },
        .{
            .name = "error_too_large",
            .text = "9223372036854775808",
            .expected = null,
        },
        .{
            .name = "error_too_small",
            .text = "-9223372036854775809",
            .expected = null,
        },
        .{
            .name = "error_empty",
            .text = "",
            .expected = null,
        },
        .{
            .name = "error_sign_only",
            .text = "-",
            .expected = null,
        },
        .{
            .name = "error_leading_zero",
            .text = "007",
            .expected = null,
        },
        .{
            .name = "error_decimal",
            .text = "1.5",
            .expected = null,
        },
        .{
            .name = "error_letters",
            .text = "12a",
            .expected = null,
        },
        .{
            .name = "error_space",
            .text = " 12",
            .expected = null,
        },
        .{
            .name = "error_two_signs",
            .text = "--1",
            .expected = null,
        },
        .{
            .name = "error_underscore",
            .text = "1_000",
            .expected = null,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqual(case.expected, parseInteger(case.text));
    }
}

test "parseDecimal" {
    const Case = struct {
        name: []const u8,
        text: []const u8,
        mark: DecimalMark = .point,
        expected: ?f64,
    };

    const cases = [_]Case{
        .{
            .name = "ok_point",
            .text = "1.5",
            .expected = 1.5,
        },
        .{
            .name = "ok_negative_below_one",
            .text = "-0.25",
            .expected = -0.25,
        },
        .{
            .name = "ok_plus",
            .text = "+2.5",
            .expected = 2.5,
        },
        .{
            .name = "ok_integer",
            .text = "10",
            .expected = 10,
        },
        .{
            .name = "ok_exponent",
            .text = "1e5",
            .expected = 100000,
        },
        .{
            .name = "ok_exponent_negative",
            .text = "2.5E-3",
            .expected = 0.0025,
        },
        .{
            .name = "error_too_large",
            .text = "1e999",
            .expected = null,
        },
        .{
            .name = "error_empty",
            .text = "",
            .expected = null,
        },
        .{
            .name = "error_no_integer_part",
            .text = ".5",
            .expected = null,
        },
        .{
            .name = "error_no_fraction",
            .text = "5.",
            .expected = null,
        },
        .{
            .name = "error_leading_zero",
            .text = "007.5",
            .expected = null,
        },
        .{
            .name = "error_two_points",
            .text = "1.2.3",
            .expected = null,
        },
        .{
            .name = "error_comma_with_point_mark",
            .text = "1,5",
            .expected = null,
        },
        .{
            .name = "ok_comma",
            .text = "1,5",
            .mark = .comma,
            .expected = 1.5,
        },
        .{
            .name = "ok_comma_negative_below_one",
            .text = "-0,25",
            .mark = .comma,
            .expected = -0.25,
        },
        .{
            .name = "ok_comma_exponent",
            .text = "2,5E-3",
            .mark = .comma,
            .expected = 0.0025,
        },
        .{
            .name = "ok_comma_integer",
            .text = "10",
            .mark = .comma,
            .expected = 10,
        },
        .{
            .name = "error_point_with_comma_mark",
            .text = "1.5",
            .mark = .comma,
            .expected = null,
        },
        .{
            .name = "error_comma_no_fraction",
            .text = "5,",
            .mark = .comma,
            .expected = null,
        },
        .{
            .name = "error_two_commas",
            .text = "1,2,3",
            .mark = .comma,
            .expected = null,
        },
        .{
            .name = "error_comma_too_long",
            .text = "1,000000000000000000000000000000000000000000000000000000000000000",
            .mark = .comma,
            .expected = null,
        },
        .{
            .name = "error_sign_in_fraction",
            .text = "1.-5",
            .expected = null,
        },
        .{
            .name = "error_empty_exponent",
            .text = "1e",
            .expected = null,
        },
        .{
            .name = "error_nothing_before_exponent",
            .text = "e5",
            .expected = null,
        },
        .{
            .name = "error_point_in_exponent",
            .text = "1e2.5",
            .expected = null,
        },
        .{
            .name = "error_underscore",
            .text = "1_000.5",
            .expected = null,
        },
        .{
            .name = "error_hexadecimal",
            .text = "0x1p3",
            .expected = null,
        },
        .{
            .name = "error_inf",
            .text = "inf",
            .expected = null,
        },
        .{
            .name = "error_nan",
            .text = "nan",
            .expected = null,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqual(case.expected, parseDecimal(case.text, case.mark));
    }
}
