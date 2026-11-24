const std = @import("std");

const report = @import("report.zig");
const tabl = @import("tabl");

const usage =
    \\usage: tabl <command> [arguments]
    \\
;

fn isCommand(input: []const u8) bool {
    return std.mem.eql(u8, input, "scan");
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var buffer: [1024]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);

    if (args.len < 3 or !isCommand(args[1])) {
        try stdout.interface.writeAll(usage);
        try stdout.interface.flush();
        return;
    }

    var csv = tabl.CsvReader.new(init.io, init.gpa, std.Io.Dir.cwd(), args[2]);
    defer csv.close();

    const scan = tabl.Scan.new(csv.reader());
    var diagnostics: tabl.diagnostic.Diagnostics = .{};

    const summary = scan.run(&diagnostics) catch {
        var error_buffer: [1024]u8 = undefined;
        var stderr: std.Io.File.Writer = .init(.stderr(), init.io, &error_buffer);
        try report.print(&stderr.interface, diagnostics.last().?);
        try stderr.interface.flush();
        csv.close();
        std.process.exit(1);
    };

    try stdout.interface.print(
        "{d} rows, {d} columns\n",
        .{ summary.rows, summary.columns },
    );

    try stdout.interface.flush();
}

test "usage names the program" {
    try std.testing.expect(std.mem.startsWith(u8, usage, "usage: tabl"));
}
