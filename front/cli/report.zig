const std = @import("std");
const tabl = @import("tabl");

const ErrorDiagnostic = tabl.diagnostic.ErrorDiagnostic;

pub fn print(
    writer: *std.Io.Writer,
    diagnostic: *const ErrorDiagnostic,
) std.Io.Writer.Error!void {
    try printLine(writer, "error: ", diagnostic);

    var current: ?*const ErrorDiagnostic = diagnostic.cause;
    while (current) |cause| : (current = cause.cause) {
        try printLine(writer, "  caused by: ", cause);
    }
}

fn printLine(
    writer: *std.Io.Writer,
    prefix: []const u8,
    diagnostic: *const ErrorDiagnostic,
) std.Io.Writer.Error!void {
    try writer.print("{s}{s}", .{ prefix, diagnostic.message });

    if (diagnostic.location) |location| {
        try writer.print(" at {s}", .{location.path});

        if (location.line) |line| {
            try writer.print(":{d}", .{line});
        }
    }

    try writer.writeAll("\n");
}

test "diagnostic with a cause" {
    const cause: ErrorDiagnostic = .{
        .layer = .infra,
        .kind = error.UnterminatedQuote,
        .message = "unterminated quote",
        .location = .{
            .path = "orders.csv",
            .line = 1_204_512,
        },
    };
    const diagnostic: ErrorDiagnostic = .{
        .layer = .app,
        .kind = error.ImportFailed,
        .message = "cannot import",
        .cause = &cause,
    };

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try print(&writer, &diagnostic);

    try std.testing.expectEqualStrings(
        \\error: cannot import
        \\  caused by: unterminated quote at orders.csv:1204512
        \\
    ,
        writer.buffered(),
    );
}

test "diagnostic without a location" {
    const cause: ErrorDiagnostic = .{
        .layer = .infra,
        .kind = error.UnterminatedQuote,
        .message = "unterminated quote",
    };
    const diagnostic: ErrorDiagnostic = .{
        .layer = .app,
        .kind = error.ImportFailed,
        .message = "cannot import",
        .cause = &cause,
    };

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try print(&writer, &diagnostic);

    try std.testing.expectEqualStrings(
        \\error: cannot import
        \\  caused by: unterminated quote
        \\
    ,
        writer.buffered(),
    );
}

test "diagnostic without location and cause" {
    const diagnostic: ErrorDiagnostic = .{
        .layer = .app,
        .kind = error.ImportFailed,
        .message = "cannot import",
    };

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try print(&writer, &diagnostic);

    try std.testing.expectEqualStrings(
        \\error: cannot import
        \\
    ,
        writer.buffered(),
    );
}

test "diagnostic with a location but without line" {
    const cause: ErrorDiagnostic = .{
        .layer = .infra,
        .kind = error.UnterminatedQuote,
        .message = "unterminated quote",
        .location = .{
            .path = "orders.csv",
        },
    };
    const diagnostic: ErrorDiagnostic = .{
        .layer = .app,
        .kind = error.ImportFailed,
        .message = "cannot import",
        .cause = &cause,
    };

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try print(&writer, &diagnostic);

    try std.testing.expectEqualStrings(
        \\error: cannot import
        \\  caused by: unterminated quote at orders.csv
        \\
    ,
        writer.buffered(),
    );
}
