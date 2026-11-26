const std = @import("std");

/// Reads `true` or `false`, in any case.
/// Returns null for any other text.
pub fn parseBoolean(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true")) return true;
    if (std.ascii.eqlIgnoreCase(text, "false")) return false;
    return null;
}

test "parseBoolean" {
    const Case = struct {
        name: []const u8,
        text: []const u8,
        expected: ?bool,
    };

    const cases = [_]Case{
        .{ .name = "ok_true", .text = "true", .expected = true },
        .{ .name = "ok_false", .text = "false", .expected = false },
        .{ .name = "ok_upper_case", .text = "TRUE", .expected = true },
        .{ .name = "ok_mixed_case", .text = "False", .expected = false },
        .{ .name = "error_empty", .text = "", .expected = null },
        .{ .name = "error_one", .text = "1", .expected = null },
        .{ .name = "error_yes", .text = "yes", .expected = null },
        .{ .name = "error_prefix", .text = "tru", .expected = null },
        .{ .name = "error_space", .text = "true ", .expected = null },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqual(case.expected, parseBoolean(case.text));
    }
}
