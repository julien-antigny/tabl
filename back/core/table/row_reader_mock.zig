const Diagnostics = @import("../diagnostic.zig").Diagnostics;
const Row = @import("row.zig").Row;
const RowReader = @import("row_reader.zig").RowReader;
const TableError = @import("errors.zig").TableError;

pub const MockRowReader = struct {
    rows: []const Row,
    /// Returned once every row has been read.
    failure: ?TableError = null,
    position: usize = 0,

    pub fn rowReader(self: *MockRowReader) RowReader {
        return .{
            .ptr = self,
            .vtable = &.{ .next = next },
        };
    }

    fn next(ptr: *anyopaque, diagnostics: *Diagnostics) TableError!?Row {
        const self: *MockRowReader = @ptrCast(@alignCast(ptr));

        if (self.position < self.rows.len) {
            const row = self.rows[self.position];
            self.position += 1;
            return row;
        }

        if (self.failure) |failure| {
            diagnostics.push(.{
                .layer = .infra,
                .kind = failure,
                .message = "mock failure",
            });
            return failure;
        }

        return null;
    }
};
