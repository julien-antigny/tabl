const std = @import("std");
const builtin = @import("builtin");
const CacheError = @import("errors.zig").CacheError;

comptime {
    if (builtin.cpu.arch.endian() != .little) {
        @compileError("the cache format is little-endian");
    }
}

pub const Ends = union(enum) {
    bits32: []const u32,
    bits64: []const u64,

    pub fn len(self: Ends) usize {
        return switch (self) {
            inline else => |ends| ends.len,
        };
    }

    pub fn at(self: Ends, row: usize) u64 {
        return switch (self) {
            inline else => |ends| ends[row],
        };
    }
};

pub const TextColumn = struct {
    ends: Ends,
    bytes: []const u8,

    pub fn new(
        ends_bytes: []align(8) const u8,
        bytes: []const u8,
        offset_width: u32,
        rows: u32,
    ) CacheError!TextColumn {
        const ends = try endsOf(ends_bytes, offset_width, rows);
        try checkLastEnd(ends, bytes.len);
        return .{ .ends = ends, .bytes = bytes };
    }

    /// Positions are clamped to `bytes`: on a damaged cache the value may be
    /// wrong, but it is never read outside the file.
    pub fn value(self: TextColumn, row: u32) []const u8 {
        std.debug.assert(row < self.ends.len());

        const end = @min(self.ends.at(row), self.bytes.len);
        const start = @min(if (row == 0) 0 else self.ends.at(row - 1), end);
        return self.bytes[@intCast(start)..@intCast(end)];
    }
};

fn endsOf(ends_bytes: []align(8) const u8, offset_width: u32, rows: u32) CacheError!Ends {
    if (offset_width != 32 and offset_width != 64) {
        return CacheError.InvalidOffsetWidth;
    }

    const expected_size = @as(u64, rows) * offset_width / 8;
    if (ends_bytes.len != expected_size) {
        return CacheError.SizeMismatch;
    }

    return switch (offset_width) {
        32 => .{ .bits32 = std.mem.bytesAsSlice(u32, ends_bytes) },
        64 => .{ .bits64 = std.mem.bytesAsSlice(u64, ends_bytes) },
        else => unreachable,
    };
}

fn checkLastEnd(ends: Ends, bytes_len: usize) CacheError!void {
    const last = if (ends.len() == 0) 0 else ends.at(ends.len() - 1);
    if (last != bytes_len) {
        return CacheError.LastEndMismatch;
    }
}

fn encode(
    buffer: []align(8) u8,
    ends: []const u64,
    offset_width: u32,
) []align(8) const u8 {
    const size = offset_width / 8;
    for (ends, 0..) |end, index| {
        const slot = buffer[index * size ..][0..size];
        switch (offset_width) {
            32 => std.mem.writeInt(u32, slot[0..4], @intCast(end), .little),
            64 => std.mem.writeInt(u64, slot[0..8], end, .little),
            else => unreachable,
        }
    }
    return buffer[0 .. ends.len * size];
}

test "value" {
    const Case = struct {
        name: []const u8,
        ends: []const u64,
        bytes: []const u8,
        offset_width: u32,
        expected: []const []const u8,
    };

    const cases = [_]Case{
        .{
            .name = "ok_32_bits",
            .ends = &.{ 5, 9 },
            .bytes = "ParisLyon",
            .offset_width = 32,
            .expected = &.{ "Paris", "Lyon" },
        },
        .{
            .name = "ok_64_bits_with_empty_value",
            .ends = &.{ 2, 2, 3 },
            .bytes = "abc",
            .offset_width = 64,
            .expected = &.{ "ab", "", "c" },
        },
        .{
            .name = "ok_first_value_empty",
            .ends = &.{ 0, 4 },
            .bytes = "Lyon",
            .offset_width = 32,
            .expected = &.{ "", "Lyon" },
        },
        .{
            .name = "ok_no_rows",
            .ends = &.{},
            .bytes = "",
            .offset_width = 32,
            .expected = &.{},
        },
        .{
            .name = "ok_damaged_decreasing_ends",
            .ends = &.{ 5, 3, 9 },
            .bytes = "ParisLyon",
            .offset_width = 32,
            .expected = &.{ "Paris", "", "isLyon" },
        },
        .{
            .name = "ok_damaged_end_past_bytes",
            .ends = &.{ 12, 9 },
            .bytes = "ParisLyon",
            .offset_width = 64,
            .expected = &.{ "ParisLyon", "" },
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var buffer: [64]u8 align(8) = undefined;
        const ends_bytes = encode(&buffer, case.ends, case.offset_width);
        const column = try TextColumn.new(
            ends_bytes,
            case.bytes,
            case.offset_width,
            @intCast(case.ends.len),
        );

        for (case.expected, 0..) |expected, row| {
            try std.testing.expectEqualStrings(
                expected,
                column.value(@intCast(row)),
            );
        }
    }
}

test "new fails" {
    const Case = struct {
        name: []const u8,
        ends: []const u64,
        bytes: []const u8,
        offset_width: u32,
        rows: u32,
        expected: CacheError,
    };

    const cases = [_]Case{
        .{
            .name = "error_invalid_offset_width",
            .ends = &.{5},
            .bytes = "Paris",
            .offset_width = 16,
            .rows = 1,
            .expected = CacheError.InvalidOffsetWidth,
        },
        .{
            .name = "error_fewer_ends_than_rows",
            .ends = &.{ 5, 9 },
            .bytes = "ParisLyon",
            .offset_width = 32,
            .rows = 3,
            .expected = CacheError.SizeMismatch,
        },
        .{
            .name = "error_last_end_before_bytes_end",
            .ends = &.{ 5, 8 },
            .bytes = "ParisLyon",
            .offset_width = 64,
            .rows = 2,
            .expected = CacheError.LastEndMismatch,
        },
        .{
            .name = "error_last_end_after_bytes_end",
            .ends = &.{ 5, 12 },
            .bytes = "ParisLyon",
            .offset_width = 32,
            .rows = 2,
            .expected = CacheError.LastEndMismatch,
        },
        .{
            .name = "error_no_rows_but_bytes",
            .ends = &.{},
            .bytes = "Paris",
            .offset_width = 32,
            .rows = 0,
            .expected = CacheError.LastEndMismatch,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var buffer: [64]u8 align(8) = undefined;
        const width = if (case.offset_width == 16) 32 else case.offset_width;
        const ends_bytes = encode(&buffer, case.ends, width);
        try std.testing.expectError(
            case.expected,
            TextColumn.new(ends_bytes, case.bytes, case.offset_width, case.rows),
        );
    }
}
