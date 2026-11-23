const std = @import("std");

const report = @import("report.zig");

const usage =
    \\usage: tabl <command> [arguments]
    \\
;

pub fn main(init: std.process.Init) !void {
    var buffer: [1024]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try stdout.interface.writeAll(usage);
    try stdout.interface.flush();
}

test "usage names the program" {
    try std.testing.expect(std.mem.startsWith(u8, usage, "usage: tabl"));
}
