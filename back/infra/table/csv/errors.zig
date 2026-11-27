const std = @import("std");
const Diagnostics = @import("../../../core/diagnostic.zig").Diagnostics;
const TableError = @import("../../../core/table/errors.zig").TableError;

pub const CsvError = error{
    UnterminatedQuote,
    UnexpectedCharAfterQuote,
    ColumnCountMismatch,
};

/// The two numbers of a row with a wrong number of values.
pub const ValueCount = struct {
    expected: usize = 0,
    found: usize = 0,
};

/// Pushes the diagnostic of a failure while reading the file at `path`,
/// then returns the error translated for the core.
/// `line` is reported for a malformed content only.
pub fn fail(
    err: anyerror,
    path: []const u8,
    line: u64,
    count: ValueCount,
    diagnostics: *Diagnostics,
) TableError {
    var buffer: [128]u8 = undefined;
    const table_error = translate(err);
    diagnostics.push(.{
        .layer = .infra,
        .kind = err,
        .message = messageOf(err, count, &buffer),
        .location = .{
            .path = path,
            .line = if (table_error == error.Malformed) line else null,
        },
    });
    return table_error;
}

fn translate(err: anyerror) TableError {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.OutOfMemory => error.OutOfMemory,
        error.UnterminatedQuote,
        error.UnexpectedCharAfterQuote,
        error.ColumnCountMismatch,
        => error.Malformed,
        else => error.Unreadable,
    };
}

fn messageOf(err: anyerror, count: ValueCount, buffer: []u8) []const u8 {
    return switch (err) {
        error.FileNotFound => "file not found",
        error.OutOfMemory => "out of memory",
        error.UnterminatedQuote => "unterminated quote",
        error.UnexpectedCharAfterQuote => "unexpected character after a closing quote",
        error.ColumnCountMismatch => std.fmt.bufPrint(
            buffer,
            "expected {d} values, found {d}",
            .{ count.expected, count.found },
        ) catch "wrong number of values",
        else => std.fmt.bufPrint(
            buffer,
            "cannot read file ({t})",
            .{err},
        ) catch "cannot read file",
    };
}
