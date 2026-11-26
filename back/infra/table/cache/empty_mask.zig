const std = @import("std");
const CacheError = @import("errors.zig").CacheError;

/// `N.empty` read back: one bit per row, set when the cell is empty.
pub const EmptyMask = struct {
    bytes: []const u8,

    pub fn new(bytes: []const u8, rows: u32) CacheError!EmptyMask {
        if (bytes.len != (@as(usize, rows) + 7) / 8) {
            return CacheError.MaskSizeMismatch;
        }
        return .{ .bytes = bytes };
    }

    pub fn isEmpty(self: EmptyMask, row: u32) bool {
        const bit: u3 = @intCast(row % 8);
        return (self.bytes[row / 8] >> bit) & 1 == 1;
    }
};

test "isEmpty" {
    const mask = try EmptyMask.new(&.{ 0xFE, 0x01 }, 9);

    try std.testing.expect(!mask.isEmpty(0));
    for (1..9) |row| {
        try std.testing.expect(mask.isEmpty(@intCast(row)));
    }
}

test "new fails on a wrong size" {
    const Case = struct {
        name: []const u8,
        bytes: []const u8,
        rows: u32,
    };

    const cases = [_]Case{
        .{ .name = "error_too_short", .bytes = &.{}, .rows = 2 },
        .{ .name = "error_too_long", .bytes = &.{ 0x00, 0x00 }, .rows = 2 },
        .{ .name = "error_one_byte_short_past_eight_rows", .bytes = &.{0x00}, .rows = 9 },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectError(CacheError.MaskSizeMismatch, EmptyMask.new(case.bytes, case.rows));
    }
}
