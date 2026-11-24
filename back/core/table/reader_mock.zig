const Diagnostics = @import("../diagnostic.zig").Diagnostics;
const Header = @import("header.zig").Header;
const Row = @import("row.zig").Row;
const Reader = @import("reader.zig").Reader;
const TableError = @import("errors.zig").TableError;

pub const MockReader = struct {
    names: []const []const u8,
    rows: []const Row,
    failure: ?TableError = null,
    position: usize = 0,

    pub fn reader(self: *MockReader) Reader {
        return .{
            .ptr = self,
            .vtable = &.{ .header = header, .next = next },
        };
    }

    fn header(ptr: *anyopaque, diagnostics: *Diagnostics) TableError!Header {
        _ = diagnostics;
        const self: *MockReader = @ptrCast(@alignCast(ptr));
        return .{ .names = self.names };
    }

    fn next(ptr: *anyopaque, diagnostics: *Diagnostics) TableError!?Row {
        const self: *MockReader = @ptrCast(@alignCast(ptr));

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
