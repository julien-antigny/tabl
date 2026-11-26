const std = @import("std");
const ColumnFile = @import("column_file.zig").ColumnFile;

/// `N.empty`: one bit per row, written a byte at a time.
pub const EmptyFile = struct {
    output: ColumnFile,
    pending_mask: u8 = 0,

    pub fn create(
        io: std.Io,
        dir: std.Io.Dir,
        index: usize,
        buffer: []u8,
    ) !EmptyFile {
        return .{
            .output = try .create(io, dir, index, "empty", .{}, buffer),
        };
    }

    pub fn close(self: EmptyFile, io: std.Io) void {
        self.output.close(io);
    }

    pub fn appendBit(self: *EmptyFile, row: u32, is_empty: bool) !void {
        const bit: u3 = @intCast(row % 8);
        if (is_empty) {
            self.pending_mask |= @as(u8, 1) << bit;
        }
        if (bit == 7) {
            try self.writePendingMask();
        }
    }

    /// Writes the last, incomplete byte if any, then flushes.
    pub fn finish(self: *EmptyFile, rows: u32) !void {
        if (rows % 8 != 0) {
            try self.writePendingMask();
        }
        try self.output.flush();
    }

    fn writePendingMask(self: *EmptyFile) !void {
        self.output.out().writeByte(self.pending_mask) catch return self.output.failure();
        self.pending_mask = 0;
    }
};
