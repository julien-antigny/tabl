const std = @import("std");
const Type = @import("../../../core/table/type/type.zig").Type;
const Value = @import("../../../core/table/value.zig").Value;
const ColumnFile = @import("column_file.zig").ColumnFile;

/// `N.values` of a fixed-width column: one value per row, little-endian.
pub const ValuesFile = struct {
    output: ColumnFile,
    width: usize,

    pub fn create(
        io: std.Io,
        dir: std.Io.Dir,
        index: usize,
        width: usize,
        buffer: []u8,
    ) !ValuesFile {
        return .{
            .output = try .create(io, dir, index, "values", .{}, buffer),
            .width = width,
        };
    }

    pub fn close(self: ValuesFile, io: std.Io) void {
        self.output.close(io);
    }

    /// Appends one value of the column type, or `width` zero bytes when empty.
    pub fn append(self: *ValuesFile, value: Value) !void {
        const out = self.output.out();
        const result = switch (value) {
            .empty => out.splatByteAll(0, self.width),
            .integer => |integer| out.writeInt(i64, integer, .little),
            .decimal => |decimal| out.writeInt(u64, @bitCast(decimal), .little),
            .date => |date| out.writeInt(i32, date, .little),
            .boolean => |boolean| out.writeByte(@intFromBool(boolean)),
            .text => unreachable,
        };
        result catch return self.output.failure();
    }

    pub fn finish(self: *ValuesFile) !void {
        try self.output.flush();
    }
};

/// Width in bytes of one value in `N.values`, null for text.
pub fn widthOf(column_type: Type) ?usize {
    return switch (column_type) {
        .integer, .decimal => 8,
        .date => 4,
        .boolean => 1,
        .text => null,
    };
}
