const std = @import("std");
const tabl = @import("tabl");

const command = @import("command.zig");
const report = @import("report.zig");
const run = @import("run.zig");

const usage =
    \\usage: tabl <command> [arguments]
    \\
    \\commands:
    \\  scan <file.csv>                       count the rows and columns of a CSV file
    \\  import <file.csv> <cache>             import a CSV file into a cache
    \\    --decimal-comma                     decimals are written with a comma (1,5)
    \\    --sample <rows>                     infer the types from the first rows only
    \\  page <cache> <first row> <row count>  print rows from a cache
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
    var err_buffer: [1024]u8 = undefined;
    var stderr: std.Io.File.Writer = .init(.stderr(), init.io, &err_buffer);
    const out = &stdout.interface;
    const err_out = &stderr.interface;

    const current = command.parse(args) catch |err| {
        if (args.len >= 2) {
            try err_out.print("error: {s}\n\n", .{command.messageOf(err)});
        }
        try err_out.writeAll(usage);
        try err_out.flush();
        std.process.exit(2);
    };

    var diagnostics: tabl.diagnostic.Diagnostics = .{};
    const result = switch (current) {
        .scan => |scan| run.scan(init, scan, out, &diagnostics),
        .import => |import| run.import(init, import, out, &diagnostics),
        .page => |page| run.page(init, page, out, err_out, &diagnostics),
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

test {
    _ = command;
    _ = report;
    _ = run;
}

test "usage names the program" {
    try std.testing.expect(std.mem.startsWith(u8, usage, "usage: tabl"));
}
