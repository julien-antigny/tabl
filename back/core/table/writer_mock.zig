const std = @import("std");
const Diagnostics = @import("../diagnostic.zig").Diagnostics;
const Header = @import("header.zig").Header;
const Row = @import("row.zig").Row;
const Writer = @import("writer.zig").Writer;
const TableError = @import("errors.zig").TableError;

pub const MockWriter = struct {
    arena: std.heap.ArenaAllocator,
    failure: ?Failure = null,
    names: []const []const u8 = &.{},
    rows: std.ArrayList([]const []const u8) = .empty,
    started: bool = false,
    finished: bool = false,

    pub const Call = enum { header, row, finish };

    pub const Failure = struct {
        call: Call,
        err: TableError,
    };

    pub fn new(allocator: std.mem.Allocator) MockWriter {
        return .{ .arena = .init(allocator) };
    }

    pub fn deinit(self: *MockWriter) void {
        self.arena.deinit();
    }

    pub fn writer(self: *MockWriter) Writer {
        return .{
            .ptr = self,
            .vtable = &.{ .header = header, .row = row, .finish = finish },
        };
    }

    fn header(
        ptr: *anyopaque,
        value: Header,
        diagnostics: *Diagnostics,
    ) TableError!void {
        const self: *MockWriter = @ptrCast(@alignCast(ptr));
        std.debug.assert(!self.started);

        try self.failOn(.header, diagnostics);
        self.names = try self.copy(value.names);
        self.started = true;
    }

    fn row(
        ptr: *anyopaque,
        value: Row,
        diagnostics: *Diagnostics,
    ) TableError!void {
        const self: *MockWriter = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.started and !self.finished);
        std.debug.assert(value.values.len == self.names.len);

        try self.failOn(.row, diagnostics);
        const values = try self.copy(value.values);
        try self.rows.append(self.arena.allocator(), values);
    }

    fn finish(ptr: *anyopaque, diagnostics: *Diagnostics) TableError!void {
        const self: *MockWriter = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.started and !self.finished);

        try self.failOn(.finish, diagnostics);
        self.finished = true;
    }

    fn failOn(
        self: *MockWriter,
        call: Call,
        diagnostics: *Diagnostics,
    ) TableError!void {
        const failure = self.failure orelse return;
        if (failure.call != call) return;

        diagnostics.push(.{
            .layer = .infra,
            .kind = failure.err,
            .message = "mock failure",
        });
        return failure.err;
    }

    fn copy(
        self: *MockWriter,
        texts: []const []const u8,
    ) error{OutOfMemory}![]const []const u8 {
        const allocator = self.arena.allocator();
        const copies = try allocator.alloc([]const u8, texts.len);
        for (texts, copies) |text, *copied| {
            copied.* = try allocator.dupe(u8, text);
        }
        return copies;
    }
};
