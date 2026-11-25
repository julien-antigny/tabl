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
pub const max_message_len: usize = 256;
pub const max_path_len: usize = 1024;

/// A stack of diagnostics, the latest on top.
///
/// It owns a copy of every message and path pushed onto it, so it must not
/// be copied once something has been pushed: pass it by pointer.
pub const Diagnostics = struct {
    entries: [max_entries]ErrorDiagnostic = undefined,
    messages: [max_entries][max_message_len]u8 = undefined,
    paths: [max_entries][max_path_len]u8 = undefined,
    size: usize = 0,

    /// Pushes `diagnostic`, copying its message and its path: they only need
    /// to stay valid during the call. Texts too long are cut.
    /// Ignored when the stack is full.
    pub fn push(self: *Diagnostics, diagnostic: ErrorDiagnostic) void {
        if (self.size == max_entries) {
            return;
        }

        var entry = diagnostic;
        entry.message = copyText(&self.messages[self.size], diagnostic.message);
        if (diagnostic.location) |location| {
            entry.location = .{
                .path = copyText(&self.paths[self.size], location.path),
                .line = location.line,
            };
        }

        self.entries[self.size] = entry;
        self.size += 1;
    }

    pub fn last(self: *const Diagnostics) ?*const ErrorDiagnostic {
        if (self.size == 0) {
            return null;
        }

        return &self.entries[self.size - 1];
    }
};

fn copyText(buffer: []u8, text: []const u8) []const u8 {
    const len = @min(buffer.len, text.len);
    @memcpy(buffer[0..len], text[0..len]);
    return buffer[0..len];
}

test "push copies the message and the path" {
    var diagnostics: Diagnostics = .{};
    var message = "cannot read".*;
    var path = "sales.tabl/meta.json".*;

    diagnostics.push(.{
        .layer = .infra,
        .kind = error.InvalidMeta,
        .message = &message,
        .location = .{ .path = &path, .line = 3 },
    });
    @memset(&message, 'x');
    @memset(&path, 'x');

    const latest = diagnostics.last().?;
    try std.testing.expectEqualStrings("cannot read", latest.message);
    try std.testing.expectEqualStrings("sales.tabl/meta.json", latest.location.?.path);
    try std.testing.expectEqual(3, latest.location.?.line);
}

test "push cuts a text that is too long" {
    var diagnostics: Diagnostics = .{};
    var long: [max_message_len + 10]u8 = undefined;
    @memset(&long, 'a');

    diagnostics.push(.{
        .layer = .infra,
        .kind = error.Whatever,
        .message = &long,
    });

    try std.testing.expectEqual(max_message_len, diagnostics.last().?.message.len);
}

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
