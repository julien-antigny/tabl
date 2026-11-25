const std = @import("std");
const Diagnostics = @import("../../core/diagnostic.zig").Diagnostics;
const Row = @import("../../core/table/row.zig").Row;
const Value = @import("../../core/table/value.zig").Value;
const table_port = @import("../../core/table/table.zig");
const Table = table_port.Table;
const Freshness = table_port.Freshness;
const MockTable = @import("../../core/table/table_mock.zig").MockTable;
const TableError = @import("../../core/table/errors.zig").TableError;
const PageError = @import("errors.zig").PageError;

pub const Result = struct {
    names: []const []const u8,
    rows: []const Row,
    cells: []const Value,
    first_row: u64,
    total_rows: u32,
    freshness: Freshness,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.rows);
    }
};

pub const Page = struct {
    table: Table,

    pub fn new(table: Table) Page {
        return .{ .table = table };
    }

    pub fn run(
        self: Page,
        first_row: u64,
        limit: u32,
        allocator: std.mem.Allocator,
        diagnostics: *Diagnostics,
    ) PageError!Result {
        const header = self.table.header(diagnostics) catch |err| return fail(err, diagnostics);
        const total_rows = self.table.rowCount(diagnostics) catch |err| return fail(err, diagnostics);
        const freshness = self.table.freshness(diagnostics) catch |err| return fail(err, diagnostics);

        const start = @min(first_row, total_rows);
        const count: usize = @intCast(@min(limit, total_rows - start));
        const columns = header.names.len;

        const rows = try allocator.alloc(Row, count);
        errdefer allocator.free(rows);
        const cells = try allocator.alloc(Value, count * columns);

        for (rows, 0..) |*row, index| {
            const row_values = cells[index * columns ..][0..columns];
            for (row_values, 0..) |*cell, column| {
                cell.* = self.table.value(@intCast(start + index), column);
            }
            row.* = .{ .values = row_values };
        }

        return .{
            .names = header.names,
            .rows = rows,
            .cells = cells,
            .first_row = first_row,
            .total_rows = total_rows,
            .freshness = freshness,
        };
    }
};

fn fail(err: TableError, diagnostics: *Diagnostics) PageError {
    diagnostics.push(.{
        .layer = .app,
        .kind = err,
        .message = "cannot read the table",
        .cause = diagnostics.last(),
    });
    return err;
}

test "run" {
    const all_rows = [_]Row{
        .{ .values = &.{ .{ .text = "Alice" }, .{ .text = "Paris" } } },
        .{ .values = &.{ .{ .text = "Bob" }, .empty } },
        .{ .values = &.{ .{ .text = "Carol" }, .{ .text = "Nantes" } } },
        .{ .values = &.{ .{ .text = "Dan" }, .{ .text = "Lille" } } },
    };

    const Case = struct {
        name: []const u8,
        first_row: u64,
        limit: u32,
        expected: []const []const u8,
    };

    const cases = [_]Case{
        .{ .name = "ok_middle", .first_row = 1, .limit = 2, .expected = &.{ "Bob", "Carol" } },
        .{ .name = "ok_cut_at_the_end", .first_row = 3, .limit = 10, .expected = &.{"Dan"} },
        .{ .name = "ok_after_the_end", .first_row = 4, .limit = 10, .expected = &.{} },
        .{ .name = "ok_far_after_the_end", .first_row = 1_000_000_000_000, .limit = 10, .expected = &.{} },
        .{ .name = "ok_no_limit", .first_row = 0, .limit = 0, .expected = &.{} },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var table: MockTable = .{ .names = &.{ "name", "city" }, .rows = &all_rows, .status = .stale };
        var diagnostics: Diagnostics = .{};

        const result = try Page.new(table.table()).run(case.first_row, case.limit, std.testing.allocator, &diagnostics);
        defer result.deinit(std.testing.allocator);

        try std.testing.expectEqual(4, result.total_rows);
        try std.testing.expectEqual(.stale, result.freshness);
        try std.testing.expectEqual(2, result.names.len);
        try std.testing.expectEqual(case.expected.len, result.rows.len);
        for (case.expected, result.rows) |name, row| {
            try std.testing.expectEqualDeep(Value{ .text = name }, row.values[0]);
        }
    }
}

test "run translates a table failure and stacks its diagnostic" {
    var table: MockTable = .{ .names = &.{"name"}, .rows = &.{}, .failure = error.Unsupported };
    var diagnostics: Diagnostics = .{};

    try std.testing.expectError(
        error.Unsupported,
        Page.new(table.table()).run(0, 20, std.testing.allocator, &diagnostics),
    );

    try std.testing.expectEqual(2, diagnostics.size);
    try std.testing.expectEqual(.app, diagnostics.last().?.layer);
    try std.testing.expectEqual(.infra, diagnostics.last().?.cause.?.layer);
}
