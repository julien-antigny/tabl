const std = @import("std");
const Diagnostics = @import("../diagnostic.zig").Diagnostics;
const Header = @import("header.zig").Header;
const Row = @import("row.zig").Row;
const Reader = @import("reader.zig").Reader;
const RowReader = @import("row_reader.zig").RowReader;
const MockRowReader = @import("row_reader_mock.zig").MockRowReader;
const TableError = @import("errors.zig").TableError;

const max_parts = 8;

pub const MockReader = struct {
    names: []const []const u8,
    /// Every row, given by a single row reader when `parts` is empty.
    rows: []const Row = &.{},
    /// Returned by the last row reader once its rows have been read.
    failure: ?TableError = null,
    /// The rows of each row reader, whatever the count asked.
    parts: []const []const Row = &.{},
    mock_row_readers: [max_parts]MockRowReader = undefined,
    row_readers: [max_parts]RowReader = undefined,

    pub fn reader(self: *MockReader) Reader {
        return .{
            .ptr = self,
            .vtable = &.{ .header = header, .rowReaders = rowReaders },
        };
    }

    fn header(ptr: *anyopaque, diagnostics: *Diagnostics) TableError!Header {
        _ = diagnostics;
        const self: *MockReader = @ptrCast(@alignCast(ptr));
        return .{ .names = self.names };
    }

    fn rowReaders(
        ptr: *anyopaque,
        count: usize,
        diagnostics: *Diagnostics,
    ) TableError![]const RowReader {
        _ = count;
        _ = diagnostics;
        const self: *MockReader = @ptrCast(@alignCast(ptr));

        const single = [_][]const Row{self.rows};
        const parts: []const []const Row = if (self.parts.len == 0) &single else self.parts;
        std.debug.assert(parts.len <= max_parts);

        for (parts, 0..) |rows, index| {
            self.mock_row_readers[index] = .{ .rows = rows };
            self.row_readers[index] = self.mock_row_readers[index].rowReader();
        }
        self.mock_row_readers[parts.len - 1].failure = self.failure;
        return self.row_readers[0..parts.len];
    }
};
