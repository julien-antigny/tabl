const std = @import("std");
const CliError = @import("errors.zig").CliError;

pub const Command = union(enum) {
    scan: ScanCommand,
    import: ImportCommand,
    page: PageCommand,
};

pub const ScanCommand = struct {
    csv_path: []const u8,
};

pub const ImportCommand = struct {
    csv_path: []const u8,
    cache_path: []const u8,
};

pub const PageCommand = struct {
    cache_path: []const u8,
    first_row: u64,
    limit: u32,
};

pub fn parse(args: []const [:0]const u8) CliError!Command {
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

pub fn messageOf(err: CliError) []const u8 {
    return switch (err) {
        CliError.UnknownCommand => "unknown command",
        CliError.MissingArguments => "missing arguments",
        CliError.InvalidNumber => "invalid number",
    };
}

fn parseNumber(comptime T: type, text: []const u8) CliError!T {
    return std.fmt.parseInt(T, text, 10) catch CliError.InvalidNumber;
}

test "parse" {
    const Case = struct {
        name: []const u8,
        args: []const [:0]const u8,
        expected: CliError!Command,
    };

    const cases = [_]Case{
        .{
            .name = "ok_scan",
            .args = &.{ "tabl", "scan", "sales.csv" },
            .expected = .{
                .scan = .{ .csv_path = "sales.csv" },
            },
        },
        .{
            .name = "ok_import",
            .args = &.{ "tabl", "import", "sales.csv", "sales.tabl" },
            .expected = .{
                .import = .{
                    .csv_path = "sales.csv",
                    .cache_path = "sales.tabl",
                },
            },
        },
        .{
            .name = "ok_page",
            .args = &.{ "tabl", "page", "sales.tabl", "40", "20" },
            .expected = .{
                .page = .{
                    .cache_path = "sales.tabl",
                    .first_row = 40,
                    .limit = 20,
                },
            },
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
        try std.testing.expectEqualDeep(case.expected, parse(case.args));
    }
}
