const std = @import("std");

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

/// Reads a decimal: an integer, then optionally a point followed by digits,
/// then optionally `e` or `E` followed by an integer.
/// Returns null when the text is not a decimal or is too large for an `f64`.
pub fn parseDecimal(text: []const u8) ?f64 {
    if (!isDecimalText(text)) return null;
    const value = std.fmt.parseFloat(f64, text) catch return null;
    if (std.math.isInf(value)) return null;
    return value;
}

fn isDecimalText(text: []const u8) bool {
    var before_exponent = text;
    if (std.mem.indexOfAny(u8, text, "eE")) |exponent_start| {
        if (!isIntegerText(text[exponent_start + 1 ..])) return false;
        before_exponent = text[0..exponent_start];
    }

    if (std.mem.indexOfScalar(u8, before_exponent, '.')) |dot| {
        const fraction = before_exponent[dot + 1 ..];
        return isIntegerText(before_exponent[0..dot]) and fraction.len > 0 and isDigits(fraction);
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

pub fn isDigits(text: []const u8) bool {
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
            .name = "error_comma",
            .text = "1,5",
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
        try std.testing.expectEqual(case.expected, parseDecimal(case.text));
    }
}
