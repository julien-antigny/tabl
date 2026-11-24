const std = @import("std");
const Diagnostics = @import("../../core/diagnostic.zig").Diagnostics;
const Row = @import("../../core/table/row.zig").Row;
const Reader = @import("../../core/table/reader.zig").Reader;
const MockReader = @import("../../core/table/reader_mock.zig").MockReader;
const TableError = @import("../../core/table/errors.zig").TableError;
const errors = @import("errors.zig");
const ScanError = errors.ScanError;

pub const Summary = struct {
    rows: u64,
    columns: usize,
};

pub const Scan = struct {
    reader: Reader,

    pub fn new(reader: Reader) Scan {
        return .{ .reader = reader };
    }

    pub fn run(self: Scan, diagnostics: *Diagnostics) ScanError!Summary {
        const header = self.reader.header(diagnostics) catch |err| {
            return fail(err, diagnostics);
        };

        var rows: u64 = 0;
        while (self.reader.next(diagnostics) catch |err| {
            return fail(err, diagnostics);
        }) |_| {
            rows += 1;
        }

        return .{
            .rows = rows,
            .columns = header.names.len,
        };
    }
};

fn fail(err: TableError, diagnostics: *Diagnostics) ScanError {
    diagnostics.push(.{
        .layer = .app,
        .kind = err,
        .message = "cannot scan the table",
        .cause = diagnostics.last(),
    });
    return err;
}

test "run" {
    const Case = struct {
        name: []const u8,
        names: []const []const u8,
        rows: []const Row,
        expected: Summary,
    };

    const cases = [_]Case{
        .{
            .name = "ok_three_rows",
            .names = &.{ "name", "city" },
            .rows = &.{
                .{ .values = &.{ "Alice", "Paris" } },
                .{ .values = &.{ "Bob", "Lyon" } },
                .{ .values = &.{ "Carol", "Nantes" } },
            },
            .expected = .{ .rows = 3, .columns = 2 },
        },
        .{
            .name = "ok_header_only",
            .names = &.{ "name", "city" },
            .rows = &.{},
            .expected = .{ .rows = 0, .columns = 2 },
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var mock: MockReader = .{ .names = case.names, .rows = case.rows };
        var diagnostics: Diagnostics = .{};

        const summary = try Scan.new(mock.reader()).run(&diagnostics);

        try std.testing.expectEqual(case.expected, summary);
        try std.testing.expectEqual(0, diagnostics.size);
    }
}

test "run translates a reader failure and stacks its diagnostic" {
    var mock: MockReader = .{
        .names = &.{"name"},
        .rows = &.{.{ .values = &.{"Alice"} }},
        .failure = error.Malformed,
    };
    var diagnostics: Diagnostics = .{};

    try std.testing.expectError(
        error.Malformed,
        Scan.new(mock.reader()).run(&diagnostics),
    );

    try std.testing.expectEqual(2, diagnostics.size);
    const latest = diagnostics.last().?;
    try std.testing.expectEqual(.app, latest.layer);
    try std.testing.expectEqual(error.Malformed, latest.kind);
    try std.testing.expectEqual(.infra, latest.cause.?.layer);
}
