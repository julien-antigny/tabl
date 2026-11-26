const std = @import("std");

pub fn isIntegerText(text: []const u8) bool {
    const has_sign = text.len > 0 and (text[0] == '+' or text[0] == '-');
    const digits = if (has_sign) text[1..] else text;

    if (digits.len == 0) return false;

    if (digits[0] == '0' and digits.len > 1) return false;

    return isDigits(digits);
}

pub fn isDecimalText(text: []const u8) bool {
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

pub fn isDigits(text: []const u8) bool {
    for (text) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }
    return true;
}

test "isIntegerText" {
    const Case = struct {
        name: []const u8,
        text: []const u8,
        expected: bool,
    };

    const cases = [_]Case{
        .{ .name = "ok_digits", .text = "123", .expected = true },
        .{ .name = "ok_zero", .text = "0", .expected = true },
        .{ .name = "ok_minus", .text = "-42", .expected = true },
        .{ .name = "ok_plus", .text = "+7", .expected = true },
        .{ .name = "error_empty", .text = "", .expected = false },
        .{ .name = "error_sign_only", .text = "-", .expected = false },
        .{ .name = "error_leading_zero", .text = "007", .expected = false },
        .{ .name = "error_decimal", .text = "1.5", .expected = false },
        .{ .name = "error_letters", .text = "12a", .expected = false },
        .{ .name = "error_space", .text = " 12", .expected = false },
        .{ .name = "error_two_signs", .text = "--1", .expected = false },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqual(case.expected, isIntegerText(case.text));
    }
}

test "isDecimalText" {
    const Case = struct {
        name: []const u8,
        text: []const u8,
        expected: bool,
    };

    const cases = [_]Case{
        .{
            .name = "ok_point",
            .text = "1.5",
            .expected = true,
        },
        .{
            .name = "ok_negative_below_one",
            .text = "-0.25",
            .expected = true,
        },
        .{
            .name = "ok_integer",
            .text = "10",
            .expected = true,
        },
        .{
            .name = "ok_exponent",
            .text = "1e5",
            .expected = true,
        },
        .{
            .name = "ok_exponent_negative",
            .text = "2.5E-3",
            .expected = true,
        },
        .{
            .name = "error_empty",
            .text = "",
            .expected = false,
        },
        .{
            .name = "error_no_integer_part",
            .text = ".5",
            .expected = false,
        },
        .{
            .name = "error_no_fraction",
            .text = "5.",
            .expected = false,
        },
        .{
            .name = "error_leading_zero",
            .text = "007.5",
            .expected = false,
        },
        .{
            .name = "error_two_points",
            .text = "1.2.3",
            .expected = false,
        },
        .{
            .name = "error_comma",
            .text = "1,5",
            .expected = false,
        },
        .{
            .name = "error_sign_in_fraction",
            .text = "1.-5",
            .expected = false,
        },
        .{
            .name = "error_empty_exponent",
            .text = "1e",
            .expected = false,
        },
        .{
            .name = "error_nothing_before_exponent",
            .text = "e5",
            .expected = false,
        },
        .{
            .name = "error_point_in_exponent",
            .text = "1e2.5",
            .expected = false,
        },
        .{
            .name = "error_inf",
            .text = "inf",
            .expected = false,
        },
        .{
            .name = "error_nan",
            .text = "nan",
            .expected = false,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqual(case.expected, isDecimalText(case.text));
    }
}
