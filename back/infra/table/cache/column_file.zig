const std = @import("std");

/// One file of a column, `N.<extension>`, written through a buffer.
pub const ColumnFile = struct {
    file: std.Io.File,
    writer: std.Io.File.Writer,

    pub fn create(
        io: std.Io,
        dir: std.Io.Dir,
        index: usize,
        extension: []const u8,
        options: std.Io.Dir.CreateFileOptions,
        buffer: []u8,
    ) !ColumnFile {
        var name: Name = undefined;
        const file = try dir.createFile(io, nameOf(&name, index, extension), options);
        return .{ .file = file, .writer = .init(file, io, buffer) };
    }

    pub fn close(self: ColumnFile, io: std.Io) void {
        self.file.close(io);
    }

    pub fn out(self: *ColumnFile) *std.Io.Writer {
        return &self.writer.interface;
    }

    pub fn flush(self: *ColumnFile) !void {
        try self.writer.flush();
    }

    /// The error behind a failed write: the file's own error when known.
    pub fn failure(self: *const ColumnFile) anyerror {
        return self.writer.err orelse error.WriteFailed;
    }
};

pub const Name = [32]u8;

/// Writes the name of a column file, such as `3.ends`, into `buffer`.
pub fn nameOf(buffer: *Name, index: usize, extension: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}.{s}", .{ index, extension }) catch unreachable;
}
