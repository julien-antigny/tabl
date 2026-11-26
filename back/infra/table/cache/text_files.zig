const std = @import("std");
const Value = @import("../../../core/table/value.zig").Value;
const column_file = @import("column_file.zig");
const ColumnFile = column_file.ColumnFile;

/// `N.ends` and `N.bytes` of a text column.
pub const TextFiles = struct {
    ends: ColumnFile,
    bytes: ColumnFile,
    offset_width: u32 = 32,
    end: u64 = 0,

    pub fn create(
        io: std.Io,
        dir: std.Io.Dir,
        index: usize,
        ends_buffer: []u8,
        bytes_buffer: []u8,
    ) !TextFiles {
        const ends: ColumnFile = try .create(io, dir, index, "ends", .{ .read = true }, ends_buffer);
        errdefer ends.close(io);
        const bytes: ColumnFile = try .create(io, dir, index, "bytes", .{}, bytes_buffer);
        return .{ .ends = ends, .bytes = bytes };
    }

    pub fn close(self: TextFiles, io: std.Io) void {
        self.ends.close(io);
        self.bytes.close(io);
    }

    /// Appends one text, or nothing for an empty value, then its end position.
    /// Positions switch to 64 bits once `end` goes past `narrow_limit`.
    pub fn append(
        self: *TextFiles,
        io: std.Io,
        dir: std.Io.Dir,
        index: usize,
        value: Value,
        narrow_limit: u64,
    ) !void {
        const text = switch (value) {
            .empty => "",
            .text => |text| text,
            .integer, .decimal, .boolean, .date => unreachable,
        };
        self.bytes.out().writeAll(text) catch return self.bytes.failure();
        self.end += text.len;

        if (self.offset_width == 32 and self.end > narrow_limit) {
            try self.widen(io, dir, index);
        }
        try self.writeEnd();
    }

    pub fn finish(self: *TextFiles) !void {
        try self.ends.flush();
        try self.bytes.flush();
    }

    fn writeEnd(self: *TextFiles) !void {
        const out = self.ends.out();
        const result = switch (self.offset_width) {
            32 => out.writeInt(u32, @intCast(self.end), .little),
            64 => out.writeInt(u64, self.end, .little),
            else => unreachable,
        };
        result catch return self.ends.failure();
    }

    /// Rewrites `N.ends` in 64 bits, through `N.ends.wide` renamed over it.
    fn widen(self: *TextFiles, io: std.Io, dir: std.Io.Dir, index: usize) !void {
        try self.ends.flush();

        var wide: ColumnFile = try .create(
            io,
            dir,
            index,
            "ends.wide",
            .{},
            self.ends.writer.interface.buffer,
        );
        errdefer wide.close(io);

        var chunk: [4096]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const read = try self.ends.file.readPositionalAll(io, &chunk, offset);
            if (read == 0) break;

            var position: usize = 0;
            while (position < read) : (position += 4) {
                const end = std.mem.readInt(u32, chunk[position..][0..4], .little);
                wide.out().writeInt(u64, end, .little) catch return wide.failure();
            }
            offset += read;
        }

        var wide_name: column_file.Name = undefined;
        var narrow_name: column_file.Name = undefined;
        try dir.rename(
            column_file.nameOf(&wide_name, index, "ends.wide"),
            dir,
            column_file.nameOf(&narrow_name, index, "ends"),
            io,
        );
        self.ends.close(io);
        self.ends = wide;
        self.offset_width = 64;
    }
};
