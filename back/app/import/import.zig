const std = @import("std");
const Diagnostics = @import("../../core/diagnostic.zig").Diagnostics;
const Row = @import("../../core/table/row.zig").Row;
const Reader = @import("../../core/table/reader.zig").Reader;
const Writer = @import("../../core/table/writer.zig").Writer;
const MockReader = @import("../../core/table/reader_mock.zig").MockReader;
const MockWriter = @import("../../core/table/writer_mock.zig").MockWriter;
const TableError = @import("../../core/table/errors.zig").TableError;
const ImportError = @import("errors.zig").ImportError;

pub const Summary = struct {
    rows: u64,
    columns: usize,
};

pub const Import = struct {
    reader: Reader,
    writer: Writer,

    pub fn new(reader: Reader, writer: Writer) Import {
        return .{ .reader = reader, .writer = writer };
    }

    pub fn run(self: Import, diagnostics: *Diagnostics) ImportError!Summary {
        const header = self.reader.header(diagnostics) catch |err| return fail(err, diagnostics);
        self.writer.header(header, diagnostics) catch |err| return fail(err, diagnostics);

        var rows: u64 = 0;
        while (self.reader.next(diagnostics) catch |err| return fail(err, diagnostics)) |row| {
            self.writer.row(row, diagnostics) catch |err| return fail(err, diagnostics);
            rows += 1;
        }

        self.writer.finish(diagnostics) catch |err| return fail(err, diagnostics);
        return .{ .rows = rows, .columns = header.names.len };
    }
};

fn fail(err: TableError, diagnostics: *Diagnostics) ImportError {
    diagnostics.push(.{
        .layer = .app,
        .kind = err,
        .message = "cannot import the table",
        .cause = diagnostics.last(),
    });
    return err;
}

test "run copies every row" {
    var reader: MockReader = .{
        .names = &.{ "name", "city" },
        .rows = &.{
            .{ .values = &.{ "Alice", "Paris" } },
            .{ .values = &.{ "Bob", "Lyon" } },
        },
    };
    var writer: MockWriter = .new(std.testing.allocator);
    defer writer.deinit();
    var diagnostics: Diagnostics = .{};

    const summary = try Import.new(reader.reader(), writer.writer()).run(&diagnostics);

    try std.testing.expectEqual(Summary{ .rows = 2, .columns = 2 }, summary);
    try std.testing.expectEqual(0, diagnostics.size);
    try std.testing.expectEqualStrings("city", writer.names[1]);
    try std.testing.expectEqual(2, writer.rows.items.len);
    try std.testing.expectEqualStrings("Bob", writer.rows.items[1][0]);
    try std.testing.expect(writer.finished);
}

test "run stops on a failure and does not finish" {
    const Case = struct {
        name: []const u8,
        reader_failure: ?TableError,
        writer_failure: ?MockWriter.Failure,
        expected: TableError,
        written_rows: usize,
    };

    const cases = [_]Case{
        .{
            .name = "error_reader",
            .reader_failure = error.Malformed,
            .writer_failure = null,
            .expected = error.Malformed,
            .written_rows = 1,
        },
        .{
            .name = "error_writer_header",
            .reader_failure = null,
            .writer_failure = .{ .call = .header, .err = error.Unwritable },
            .expected = error.Unwritable,
            .written_rows = 0,
        },
        .{
            .name = "error_writer_row",
            .reader_failure = null,
            .writer_failure = .{ .call = .row, .err = error.Unwritable },
            .expected = error.Unwritable,
            .written_rows = 0,
        },
        .{
            .name = "error_writer_finish",
            .reader_failure = null,
            .writer_failure = .{ .call = .finish, .err = error.Unwritable },
            .expected = error.Unwritable,
            .written_rows = 1,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var reader: MockReader = .{
            .names = &.{"name"},
            .rows = &.{.{ .values = &.{"Alice"} }},
            .failure = case.reader_failure,
        };
        var writer: MockWriter = .new(std.testing.allocator);
        defer writer.deinit();
        writer.failure = case.writer_failure;
        var diagnostics: Diagnostics = .{};

        try std.testing.expectError(
            case.expected,
            Import.new(reader.reader(), writer.writer()).run(&diagnostics),
        );

        try std.testing.expect(!writer.finished);
        try std.testing.expectEqual(case.written_rows, writer.rows.items.len);
        try std.testing.expectEqual(2, diagnostics.size);
        const latest = diagnostics.last().?;
        try std.testing.expectEqual(.app, latest.layer);
        try std.testing.expectEqual(.infra, latest.cause.?.layer);
    }
}
