const std = @import("std");
const Diagnostics = @import("../../core/diagnostic.zig").Diagnostics;
const max_message_len = @import("../../core/diagnostic.zig").max_message_len;
const Row = @import("../../core/table/row.zig").Row;
const Value = @import("../../core/table/value.zig").Value;
const Reader = @import("../../core/table/reader.zig").Reader;
const Writer = @import("../../core/table/writer.zig").Writer;
const MockReader = @import("../../core/table/reader_mock.zig").MockReader;
const MockWriter = @import("../../core/table/writer_mock.zig").MockWriter;
const TableError = @import("../../core/table/errors.zig").TableError;
const ImportError = @import("errors.zig").ImportError;
const Header = @import("../../core/table/header.zig").Header;
const ColumnType = @import("../../core/table/type/type.zig").ColumnType;
const DecimalMark = @import("../../core/table/type/type.zig").DecimalMark;
const Candidates = @import("../../core/table/type/inference.zig").Candidates;
const TypeInference = @import("../../core/table/type/inference.zig").TypeInference;
const convert = @import("../../core/table/type/convert.zig").convert;

pub const Summary = struct {
    rows: u64,
    columns: usize,
};

pub const ImportOptions = struct {
    /// The one used by the decimals of the whole source.
    decimal_mark: DecimalMark = .point,
    /// How many rows the types are inferred from: null reads every row.
    /// A value after the sample that does not fit its type stops the import.
    sample_rows: ?u64 = null,
};

pub const Import = struct {
    reader: Reader,
    writer: Writer,
    options: ImportOptions,

    pub fn new(reader: Reader, writer: Writer, options: ImportOptions) Import {
        return .{ .reader = reader, .writer = writer, .options = options };
    }

    /// Reads the source twice: once to infer the type of each column,
    /// then again to write every row with its values converted.
    pub fn run(
        self: Import,
        allocator: std.mem.Allocator,
        diagnostics: *Diagnostics,
    ) ImportError!Summary {
        return self.importTable(allocator, diagnostics) catch |err| fail(err, diagnostics);
    }

    fn importTable(
        self: Import,
        allocator: std.mem.Allocator,
        diagnostics: *Diagnostics,
    ) ImportError!Summary {
        const header = try self.reader.header(diagnostics);

        const types = try allocator.alloc(ColumnType, header.names.len);
        defer allocator.free(types);
        try self.inferTypes(allocator, types, diagnostics);

        try self.writer.header(header, types, diagnostics);
        const rows = try self.copyRows(allocator, header, types, diagnostics);
        try self.writer.finish(diagnostics);

        return .{ .rows = rows, .columns = header.names.len };
    }

    fn inferTypes(
        self: Import,
        allocator: std.mem.Allocator,
        types: []ColumnType,
        diagnostics: *Diagnostics,
    ) TableError!void {
        const candidates = try allocator.alloc(Candidates, types.len);
        defer allocator.free(candidates);
        @memset(candidates, .{});

        const inference: TypeInference = .new(candidates, self.options.decimal_mark);
        const row_reader = (try self.reader.rowReaders(1, diagnostics))[0];
        const sample_rows = self.options.sample_rows orelse std.math.maxInt(u64);
        var rows: u64 = 0;
        while (rows < sample_rows) : (rows += 1) {
            const row = try row_reader.next(diagnostics) orelse break;
            inference.observe(row.values);
        }
        inference.result(types);
    }

    fn copyRows(
        self: Import,
        allocator: std.mem.Allocator,
        header: Header,
        types: []const ColumnType,
        diagnostics: *Diagnostics,
    ) ImportError!u64 {
        const values = try allocator.alloc(Value, types.len);
        defer allocator.free(values);

        const row_reader = (try self.reader.rowReaders(1, diagnostics))[0];
        var rows: u64 = 0;
        while (try row_reader.next(diagnostics)) |row| {
            for (row.values, types, values, header.names) |value, column_type, *converted, name| {
                converted.* = convert(value, column_type, self.options.decimal_mark) orelse
                    return mismatch(rows + 1, name, value.text, column_type, diagnostics);
            }
            try self.writer.row(.{ .values = values }, diagnostics);
            rows += 1;
        }
        return rows;
    }
};

/// Reports a value that does not fit the type inferred from the sample.
/// `row` counts from 1, without the header.
fn mismatch(
    row: u64,
    name: []const u8,
    text: []const u8,
    column_type: ColumnType,
    diagnostics: *Diagnostics,
) ImportError {
    var buffer: [max_message_len]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "row {d}, column \"{s}\": \"{s}\" is not of type {t}, inferred from the sample",
        .{ row, name, text, std.meta.activeTag(column_type) },
    ) catch "a value is not of the type inferred from the sample";
    diagnostics.push(.{
        .layer = .app,
        .kind = error.TypeMismatch,
        .message = message,
    });
    return error.TypeMismatch;
}

fn fail(err: ImportError, diagnostics: *Diagnostics) ImportError {
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
            .{ .values = &.{ .{ .text = "Alice" }, .{ .text = "Paris" } } },
            .{ .values = &.{ .{ .text = "Bob" }, .empty } },
        },
    };
    var writer: MockWriter = .new(std.testing.allocator);
    defer writer.deinit();
    var diagnostics: Diagnostics = .{};

    const summary = try Import.new(reader.reader(), writer.writer(), .{}).run(std.testing.allocator, &diagnostics);

    try std.testing.expectEqual(Summary{ .rows = 2, .columns = 2 }, summary);
    try std.testing.expectEqual(0, diagnostics.size);
    try std.testing.expectEqualStrings("city", writer.names[1]);
    try std.testing.expectEqual(2, writer.rows.items.len);
    try std.testing.expectEqualDeep(Value{ .text = "Bob" }, writer.rows.items[1][0]);
    try std.testing.expectEqualDeep(Value.empty, writer.rows.items[1][1]);
    try std.testing.expect(writer.finished);
}

test "run converts the values to the inferred types" {
    var reader: MockReader = .{
        .names = &.{ "id", "city", "day" },
        .rows = &.{
            .{ .values = &.{ .{ .text = "1" }, .{ .text = "Paris" }, .{ .text = "02/01/1970" } } },
            .{ .values = &.{ .{ .text = "2" }, .empty, .empty } },
        },
    };
    var writer: MockWriter = .new(std.testing.allocator);
    defer writer.deinit();
    var diagnostics: Diagnostics = .{};

    _ = try Import.new(reader.reader(), writer.writer(), .{}).run(std.testing.allocator, &diagnostics);

    try std.testing.expectEqualDeep(
        &[_]ColumnType{ .integer, .text, .{ .date = .day_month_year_slash } },
        writer.types,
    );
    try std.testing.expectEqualDeep(
        &[_]Value{ .{ .integer = 1 }, .{ .text = "Paris" }, .{ .date = 1 } },
        writer.rows.items[0],
    );
    try std.testing.expectEqualDeep(
        &[_]Value{ .{ .integer = 2 }, .empty, .empty },
        writer.rows.items[1],
    );
}

test "run reads decimals with a comma" {
    var reader: MockReader = .{
        .names = &.{ "price", "code" },
        .rows = &.{
            .{ .values = &.{ .{ .text = "1,5" }, .{ .text = "1.5" } } },
            .{ .values = &.{ .{ .text = "2" }, .{ .text = "2" } } },
        },
    };
    var writer: MockWriter = .new(std.testing.allocator);
    defer writer.deinit();
    var diagnostics: Diagnostics = .{};

    _ = try Import.new(reader.reader(), writer.writer(), .{ .decimal_mark = .comma }).run(std.testing.allocator, &diagnostics);

    try std.testing.expectEqualDeep(&[_]ColumnType{ .decimal, .text }, writer.types);
    try std.testing.expectEqualDeep(
        &[_]Value{ .{ .decimal = 1.5 }, .{ .text = "1.5" } },
        writer.rows.items[0],
    );
    try std.testing.expectEqualDeep(
        &[_]Value{ .{ .decimal = 2 }, .{ .text = "2" } },
        writer.rows.items[1],
    );
}

test "run infers the types from the sample only" {
    var reader: MockReader = .{
        .names = &.{ "id", "note" },
        .rows = &.{
            .{ .values = &.{ .{ .text = "1" }, .empty } },
            .{ .values = &.{ .{ .text = "2" }, .{ .text = "3" } } },
        },
    };
    var writer: MockWriter = .new(std.testing.allocator);
    defer writer.deinit();
    var diagnostics: Diagnostics = .{};

    const summary = try Import.new(reader.reader(), writer.writer(), .{ .sample_rows = 1 })
        .run(std.testing.allocator, &diagnostics);

    try std.testing.expectEqual(2, summary.rows);
    try std.testing.expectEqualDeep(&[_]ColumnType{ .integer, .text }, writer.types);
    try std.testing.expectEqualDeep(
        &[_]Value{ .{ .integer = 2 }, .{ .text = "3" } },
        writer.rows.items[1],
    );
}

test "run stops on a value that does not fit the sample" {
    var reader: MockReader = .{
        .names = &.{"age"},
        .rows = &.{
            .{ .values = &.{.{ .text = "31" }} },
            .{ .values = &.{.{ .text = "N/A" }} },
        },
    };
    var writer: MockWriter = .new(std.testing.allocator);
    defer writer.deinit();
    var diagnostics: Diagnostics = .{};

    try std.testing.expectError(
        error.TypeMismatch,
        Import.new(reader.reader(), writer.writer(), .{ .sample_rows = 1 })
            .run(std.testing.allocator, &diagnostics),
    );

    try std.testing.expect(!writer.finished);
    try std.testing.expectEqual(1, writer.rows.items.len);
    try std.testing.expectEqual(2, diagnostics.size);
    const cause = diagnostics.last().?.cause.?;
    try std.testing.expectEqual(.app, cause.layer);
    try std.testing.expectEqualStrings(
        "row 2, column \"age\": \"N/A\" is not of type integer, inferred from the sample",
        cause.message,
    );
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
            .written_rows = 0,
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
            .rows = &.{.{ .values = &.{.{ .text = "Alice" }} }},
            .failure = case.reader_failure,
        };
        var writer: MockWriter = .new(std.testing.allocator);
        defer writer.deinit();
        writer.failure = case.writer_failure;
        var diagnostics: Diagnostics = .{};

        try std.testing.expectError(
            case.expected,
            Import.new(reader.reader(), writer.writer(), .{}).run(std.testing.allocator, &diagnostics),
        );

        try std.testing.expect(!writer.finished);
        try std.testing.expectEqual(case.written_rows, writer.rows.items.len);
        try std.testing.expectEqual(2, diagnostics.size);
        const latest = diagnostics.last().?;
        try std.testing.expectEqual(.app, latest.layer);
        try std.testing.expectEqual(.infra, latest.cause.?.layer);
    }
}
