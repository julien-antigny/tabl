const std = @import("std");
const Type = @import("type.zig").Type;

pub const TypeInference = struct {
    candidates: []std.EnumSet(Type),

    pub fn inference(self: TypeInference, inputs: []const []const u8) void {
        for (inputs, 0..) |value, index| {
            if (!isIntegerText(value)) {
                self.candidates[index].remove(.integer);
            }
        }
    }
};

fn isIntegerText(text: []const u8) bool {
    const has_sign = text.len > 0 and (text[0] == '+' or text[0] == '-');
    const digits = if (has_sign) text[1..] else text;

    if (digits.len == 0) return false;

    if (digits[0] == '0' and digits.len > 1) return false;

    for (digits) |char| {
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

test "inference" {
    const Set = std.EnumSet(Type);

    const Case = struct {
        name: []const u8,
        rows: []const []const []const u8,
        expected: []const Set,
    };

    const without_integer = Set.initMany(&.{ .decimal, .boolean, .date, .text });

    const cases = [_]Case{
        .{
            .name = "ok_no_rows",
            .rows = &.{},
            .expected = &.{ .full, .full },
        },
        .{
            .name = "ok_integers_kept",
            .rows = &.{
                &.{ "1", "-2" },
                &.{ "30", "+4" },
            },
            .expected = &.{ .full, .full },
        },
        .{
            .name = "ok_text_removes_integer",
            .rows = &.{
                &.{ "1", "a" },
                &.{ "2", "3" },
            },
            .expected = &.{ .full, without_integer },
        },
        .{
            .name = "ok_removed_stays_removed",
            .rows = &.{
                &.{ "x", "1" },
                &.{ "2", "2" },
            },
            .expected = &.{ without_integer, .full },
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var candidates = [_]Set{ .full, .full };
        const inference: TypeInference = .{ .candidates = &candidates };
        for (case.rows) |row| {
            inference.inference(row);
        }

        try std.testing.expectEqualDeep(case.expected, &candidates);
    }
}
