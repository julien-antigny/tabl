const std = @import("std");
const Diagnostics = @import("../diagnostic.zig").Diagnostics;
const Header = @import("header.zig").Header;
const Row = @import("row.zig").Row;
const table_port = @import("table.zig");
const Table = table_port.Table;
const Freshness = table_port.Freshness;
const TableError = @import("errors.zig").TableError;
const Value = @import("value.zig").Value;

pub const MockTable = struct {
    names: []const []const u8,
    rows: []const Row,
    status: Freshness = .fresh,
    failure: ?TableError = null,
    opened: bool = false,

    pub fn table(self: *MockTable) Table {
        return .{
            .ptr = self,
            .vtable = &.{
                .header = header,
                .rowCount = rowCount,
                .value = value,
                .freshness = freshness,
            },
        };
    }

    fn header(ptr: *anyopaque, diagnostics: *Diagnostics) TableError!Header {
        const self: *MockTable = @ptrCast(@alignCast(ptr));
        try self.open(diagnostics);
        return .{ .names = self.names };
    }

    fn rowCount(ptr: *anyopaque, diagnostics: *Diagnostics) TableError!u32 {
        const self: *MockTable = @ptrCast(@alignCast(ptr));
        try self.open(diagnostics);
        return @intCast(self.rows.len);
    }

    fn value(ptr: *anyopaque, row: u32, column: usize) Value {
        const self: *MockTable = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.opened);
        std.debug.assert(row < self.rows.len);
        std.debug.assert(column < self.names.len);
        return self.rows[row].values[column];
    }

    fn freshness(ptr: *anyopaque, diagnostics: *Diagnostics) TableError!Freshness {
        const self: *MockTable = @ptrCast(@alignCast(ptr));
        try self.open(diagnostics);
        return self.status;
    }

    fn open(self: *MockTable, diagnostics: *Diagnostics) TableError!void {
        if (self.failure) |failure| {
            diagnostics.push(.{
                .layer = .infra,
                .kind = failure,
                .message = "mock failure",
            });
            return failure;
        }
        self.opened = true;
    }
};
