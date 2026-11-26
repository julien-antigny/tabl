const std = @import("std");

pub fn isBooleanText(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "true") or std.ascii.eqlIgnoreCase(text, "false");
}

test "isBooleanText" {
    const Case = struct {
        name: []const u8,
        text: []const u8,
        expected: bool,
    };

    const cases = [_]Case{
        .{ .name = "ok_true", .text = "true", .expected = true },
        .{ .name = "ok_false", .text = "false", .expected = true },
        .{ .name = "ok_upper_case", .text = "TRUE", .expected = true },
        .{ .name = "ok_mixed_case", .text = "False", .expected = true },
        .{ .name = "error_empty", .text = "", .expected = false },
        .{ .name = "error_one", .text = "1", .expected = false },
        .{ .name = "error_yes", .text = "yes", .expected = false },
        .{ .name = "error_prefix", .text = "tru", .expected = false },
        .{ .name = "error_space", .text = "true ", .expected = false },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqual(case.expected, isBooleanText(case.text));
    }
}
