const std = @import("std");

pub const ErrorLayer = enum {
    core,
    infra,
    app,
};

pub const ErrorLocation = struct {
    path: []const u8,
    line: ?u64 = null,
};

pub const ErrorDiagnostic = struct {
    layer: ErrorLayer,
    message: []const u8,
    cause: ?*const ErrorDiagnostic = null,
    kind: anyerror,
    location: ?ErrorLocation = null,
};

pub const max_entries: usize = 8;

pub const Diagnostics = struct {
    entries: [max_entries]ErrorDiagnostic = undefined,
    size: usize = 0,

    pub fn push(self: *Diagnostics, diagnostic: ErrorDiagnostic) void {
        if (self.size == max_entries) {
            return;
        }

        self.entries[self.size] = diagnostic;
        self.size += 1;
    }

    pub fn last(self: *const Diagnostics) ?*const ErrorDiagnostic {
        if (self.size == 0) {
            return null;
        }

        return &self.entries[self.size - 1];
    }
};

test "last is null on an empty stack" {
    const diagnostics: Diagnostics = .{};

    try std.testing.expect(diagnostics.last() == null);
}

test "last points to the latest entry and keeps the cause chain" {
    var diagnostics: Diagnostics = .{};

    diagnostics.push(.{
        .layer = .infra,
        .kind = error.UnterminatedQuote,
        .message = "unterminated quote",
    });
    diagnostics.push(.{
        .layer = .app,
        .kind = error.ScanFailed,
        .message = "cannot scan",
        .cause = diagnostics.last(),
    });

    const latest = diagnostics.last().?;
    try std.testing.expectEqualStrings("cannot scan", latest.message);
    try std.testing.expectEqual(ErrorLayer.infra, latest.cause.?.layer);
    try std.testing.expectEqual(&diagnostics.entries[0], latest.cause.?);
}

test "push keeps the first entries when the stack is full" {
    var diagnostics: Diagnostics = .{};

    for (0..max_entries + 1) |_| {
        diagnostics.push(.{
            .layer = .infra,
            .kind = error.Whatever,
            .message = "entry",
        });
    }

    try std.testing.expectEqual(max_entries, diagnostics.size);
}
