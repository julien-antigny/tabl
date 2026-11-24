const std = @import("std");

const report = @import("report.zig");
const tabl = @import("tabl");
const CliError = @import("errors.zig").CliError;

const usage =
    \\usage: tabl <command> [arguments]
    \\
    \\commands:
    \\  scan <file.csv>                       count the rows and columns of a CSV file
    \\  import <file.csv> <cache>             import a CSV file into a cache
    \\  page <cache> <first row> <row count>  print rows from a cache
    \\
;

const Command = union(enum) {
    scan: ScanCommand,
    import: ImportCommand,
    page: PageCommand,
};

const ScanCommand = struct {
    csv_path: []const u8,
};

const ImportCommand = struct {
    csv_path: []const u8,
    cache_path: []const u8,
};

const PageCommand = struct {
    cache_path: []const u8,
    first_row: u64,
    limit: u32,
};

fn parseCommand(args: []const [:0]const u8) CliError!Command {
    if (args.len < 2) return CliError.MissingArguments;
    const name = args[1];

    if (std.mem.eql(u8, name, "scan")) {
        if (args.len < 3) return CliError.MissingArguments;
        return .{ .scan = .{ .csv_path = args[2] } };
    }

    if (std.mem.eql(u8, name, "import")) {
        if (args.len < 4) return CliError.MissingArguments;
        return .{ .import = .{ .csv_path = args[2], .cache_path = args[3] } };
    }

    if (std.mem.eql(u8, name, "page")) {
        if (args.len < 5) return CliError.MissingArguments;
        return .{ .page = .{
            .cache_path = args[2],
            .first_row = try parseNumber(u64, args[3]),
            .limit = try parseNumber(u32, args[4]),
        } };
    }

    return CliError.UnknownCommand;
}

fn parseNumber(comptime T: type, text: []const u8) CliError!T {
    return std.fmt.parseInt(T, text, 10) catch CliError.InvalidNumber;
}

fn usageMessage(err: CliError) []const u8 {
    return switch (err) {
        CliError.UnknownCommand => "unknown command",
        CliError.MissingArguments => "missing arguments",
        CliError.InvalidNumber => "invalid number",
    };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
    var err_buffer: [1024]u8 = undefined;
    var stderr: std.Io.File.Writer = .init(.stderr(), init.io, &err_buffer);
    const out = &stdout.interface;
    const err_out = &stderr.interface;

    const command = parseCommand(args) catch |err| {
        if (args.len >= 2) try err_out.print("error: {s}\n\n", .{usageMessage(err)});
        try err_out.writeAll(usage);
        try err_out.flush();
        std.process.exit(2);
    };

    var diagnostics: tabl.diagnostic.Diagnostics = .{};
    const result = switch (command) {
        .scan => |scan| runScan(init, scan, out, &diagnostics),
        .import => |import| runImport(init, import, out, &diagnostics),
        .page => |page| runPage(init, page, out, err_out, &diagnostics),
    };

    result catch |err| {
        try out.flush();
        if (diagnostics.last()) |diagnostic| {
            try report.print(err_out, diagnostic);
        } else {
            try err_out.print("error: {t}\n", .{err});
        }
        try err_out.flush();
        std.process.exit(1);
    };

    try out.flush();
    try err_out.flush();
}

fn runScan(
    init: std.process.Init,
    command: ScanCommand,
    out: *std.Io.Writer,
    diagnostics: *tabl.diagnostic.Diagnostics,
) !void {
    var csv = tabl.CsvReader.new(init.io, init.gpa, std.Io.Dir.cwd(), command.csv_path);
    defer csv.close();

    const summary = try tabl.Scan.new(csv.reader()).run(diagnostics);
    try out.print("{d} rows, {d} columns\n", .{ summary.rows, summary.columns });
}

fn runImport(
    init: std.process.Init,
    command: ImportCommand,
    out: *std.Io.Writer,
    diagnostics: *tabl.diagnostic.Diagnostics,
) !void {
    var csv = tabl.CsvReader.new(init.io, init.gpa, std.Io.Dir.cwd(), command.csv_path);
    defer csv.close();
    var cache = tabl.CacheWriter.new(
        init.io,
        init.gpa,
        std.Io.Dir.cwd(),
        command.cache_path,
        command.csv_path,
    );
    defer cache.close();

    const summary = try tabl.Import.new(csv.reader(), cache.writer()).run(diagnostics);
    try out.print("{d} rows, {d} columns imported into {s}\n", .{
        summary.rows,
        summary.columns,
        command.cache_path,
    });
}

fn runPage(
    init: std.process.Init,
    command: PageCommand,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    diagnostics: *tabl.diagnostic.Diagnostics,
) !void {
    var cache = tabl.CacheTable.new(init.io, init.gpa, std.Io.Dir.cwd(), command.cache_path);
    defer cache.close();

    const page = try tabl.Page.new(cache.table()).run(
        command.first_row,
        command.limit,
        init.gpa,
        diagnostics,
    );
    defer page.deinit(init.gpa);

    if (page.freshness == .stale) {
        try err_out.writeAll("warning: the source file has changed since the import\n");
    }

    try printValues(out, page.names);
    for (page.rows) |row| {
        try printValues(out, row.values);
    }

    if (page.rows.len == 0) {
        try err_out.print("no rows (the table has {d} rows)\n", .{page.total_rows});
    } else {
        try err_out.print("rows {d} to {d} of {d}\n", .{
            page.first_row,
            page.first_row + page.rows.len - 1,
            page.total_rows,
        });
    }
}

fn printValues(out: *std.Io.Writer, values: []const []const u8) !void {
    for (values, 0..) |value, index| {
        if (index > 0) try out.writeByte('\t');
        try out.writeAll(value);
    }
    try out.writeByte('\n');
}

test "usage names the program" {
    try std.testing.expect(std.mem.startsWith(u8, usage, "usage: tabl"));
}

test "parseCommand" {
    const Case = struct {
        name: []const u8,
        args: []const [:0]const u8,
        expected: CliError!Command,
    };

    const cases = [_]Case{
        .{
            .name = "ok_scan",
            .args = &.{ "tabl", "scan", "sales.csv" },
            .expected = .{ .scan = .{ .csv_path = "sales.csv" } },
        },
        .{
            .name = "ok_import",
            .args = &.{ "tabl", "import", "sales.csv", "sales.tabl" },
            .expected = .{ .import = .{ .csv_path = "sales.csv", .cache_path = "sales.tabl" } },
        },
        .{
            .name = "ok_page",
            .args = &.{ "tabl", "page", "sales.tabl", "40", "20" },
            .expected = .{ .page = .{ .cache_path = "sales.tabl", .first_row = 40, .limit = 20 } },
        },
        .{
            .name = "error_no_command",
            .args = &.{"tabl"},
            .expected = CliError.MissingArguments,
        },
        .{
            .name = "error_unknown_command",
            .args = &.{ "tabl", "sort", "sales.csv" },
            .expected = CliError.UnknownCommand,
        },
        .{
            .name = "error_import_without_cache",
            .args = &.{ "tabl", "import", "sales.csv" },
            .expected = CliError.MissingArguments,
        },
        .{
            .name = "error_page_not_a_number",
            .args = &.{ "tabl", "page", "sales.tabl", "abc", "20" },
            .expected = CliError.InvalidNumber,
        },
        .{
            .name = "error_page_negative",
            .args = &.{ "tabl", "page", "sales.tabl", "0", "-5" },
            .expected = CliError.InvalidNumber,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqualDeep(case.expected, parseCommand(case.args));
    }
}
