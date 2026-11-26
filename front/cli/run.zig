const std = @import("std");
const tabl = @import("tabl");
const ScanCommand = @import("command.zig").ScanCommand;
const ImportCommand = @import("command.zig").ImportCommand;
const PageCommand = @import("command.zig").PageCommand;

const Diagnostics = tabl.diagnostic.Diagnostics;

pub fn scan(
    init: std.process.Init,
    command: ScanCommand,
    out: *std.Io.Writer,
    diagnostics: *Diagnostics,
) !void {
    var csv = tabl.CsvReader.new(
        init.io,
        init.gpa,
        std.Io.Dir.cwd(),
        command.csv_path,
    );
    defer csv.close();

    const summary = try tabl.Scan.new(csv.reader()).run(diagnostics);
    try out.print(
        "{d} rows, {d} columns\n",
        .{ summary.rows, summary.columns },
    );
}

pub fn import(
    init: std.process.Init,
    command: ImportCommand,
    out: *std.Io.Writer,
    diagnostics: *Diagnostics,
) !void {
    var csv = tabl.CsvReader.new(
        init.io,
        init.gpa,
        std.Io.Dir.cwd(),
        command.csv_path,
    );
    defer csv.close();
    var cache = tabl.CacheWriter.new(
        init.io,
        init.gpa,
        std.Io.Dir.cwd(),
        command.cache_path,
        command.csv_path,
    );
    defer cache.close();

    const summary = try tabl.Import.new(
        csv.reader(),
        cache.writer(),
        command.options,
    ).run(init.gpa, diagnostics);
    try out.print("{d} rows, {d} columns imported into {s}\n", .{
        summary.rows,
        summary.columns,
        command.cache_path,
    });
}

pub fn page(
    init: std.process.Init,
    command: PageCommand,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    diagnostics: *Diagnostics,
) !void {
    var cache = tabl.CacheTable.new(
        init.io,
        init.gpa,
        std.Io.Dir.cwd(),
        command.cache_path,
    );
    defer cache.close();

    const result = try tabl.Page.new(cache.table()).run(
        command.first_row,
        command.limit,
        init.gpa,
        diagnostics,
    );
    defer result.deinit(init.gpa);

    switch (result.freshness) {
        .fresh => {},
        .stale => try err_out.writeAll(
            "warning: the source file has changed since the import\n\n",
        ),
        .source_missing => try err_out.writeAll(
            "note: the source file no longer exists, the data comes from the cache only\n\n",
        ),
    }
    try err_out.flush();

    try printNames(out, result.names);
    for (result.rows) |row| {
        try printValues(out, row.values);
    }

    if (result.rows.len == 0) {
        try err_out.print(
            "no rows (the table has {d} rows)\n",
            .{result.total_rows},
        );
    } else {
        try err_out.print("rows {d} to {d} of {d}\n", .{
            result.first_row,
            result.first_row + result.rows.len - 1,
            result.total_rows,
        });
    }
}

fn printNames(out: *std.Io.Writer, names: []const []const u8) !void {
    for (names, 0..) |name, index| {
        if (index > 0) try out.writeByte('\t');
        try out.writeAll(name);
    }
    try out.writeByte('\n');
}

fn printValues(out: *std.Io.Writer, values: []const tabl.Value) !void {
    for (values, 0..) |value, index| {
        if (index > 0) try out.writeByte('\t');
        switch (value) {
            .empty => {},
            .text => |text| try out.writeAll(text),
            .integer => |integer| try out.print("{d}", .{integer}),
            .decimal => |decimal| try out.print("{d}", .{decimal}),
            .boolean => |boolean| try out.print("{}", .{boolean}),
            .date => |days| try printDate(out, tabl.CalendarDate.fromDays(days)),
        }
    }
    try out.writeByte('\n');
}

/// Prints a date as YYYY-MM-DD. A year before 1 or after 9999, only found
/// in a damaged cache, is printed as is.
fn printDate(out: *std.Io.Writer, date: tabl.CalendarDate) !void {
    if (std.math.cast(u16, date.year)) |year| {
        if (year >= 1 and year <= 9999) {
            return out.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ year, date.month, date.day });
        }
    }
    try out.print("{d}-{d:0>2}-{d:0>2}", .{ date.year, date.month, date.day });
}

test "printValues" {
    var buffer: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    try printValues(&out, &.{
        .{ .text = "Paris" },
        .empty,
        .{ .integer = -31 },
        .{ .decimal = 1.5 },
        .{ .boolean = true },
        .{ .date = 19797 },
        .{ .date = -719162 },
    });

    try std.testing.expectEqualStrings(
        "Paris\t\t-31\t1.5\ttrue\t2024-03-15\t0001-01-01\n",
        out.buffered(),
    );
}
