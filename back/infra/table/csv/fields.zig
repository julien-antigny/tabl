const std = @import("std");
const CsvError = @import("errors.zig").CsvError;

pub const Field = struct {
    text: []const u8,
    has_escaped_quotes: bool = false,
};

pub const Fields = struct {
    text: []const u8,
    separator: u8,
    position: usize = 0,
    done: bool = false,

    pub fn next(self: *Fields) CsvError!?Field {
        if (self.done) return null;

        if (self.isQuoteAt(self.position)) {
            return try self.nextQuoted();
        }
        return self.nextPlain();
    }

    fn nextPlain(self: *Fields) Field {
        const start = self.position;

        while (self.position < self.text.len) : (self.position += 1) {
            if (self.text[self.position] == self.separator) {
                const field: Field = .{ .text = self.text[start..self.position] };
                self.position += 1;
                return field;
            }
        }

        self.done = true;
        return .{ .text = self.text[start..] };
    }

    fn nextQuoted(self: *Fields) CsvError!Field {
        const start = self.position + 1;
        var has_escaped_quotes = false;

        var index = start;
        while (index < self.text.len) : (index += 1) {
            if (self.text[index] != '"') continue;

            if (self.isQuoteAt(index + 1)) {
                has_escaped_quotes = true;
                index += 1;
                continue;
            }

            try self.moveAfterClosingQuote(index);
            return .{
                .text = self.text[start..index],
                .has_escaped_quotes = has_escaped_quotes,
            };
        }

        return error.UnterminatedQuote;
    }

    fn moveAfterClosingQuote(self: *Fields, quote: usize) CsvError!void {
        const following = quote + 1;

        if (following == self.text.len) {
            self.done = true;
            return;
        }

        if (self.text[following] != self.separator) {
            return error.UnexpectedCharAfterQuote;
        }

        self.position = following + 1;
    }

    fn isQuoteAt(self: *const Fields, index: usize) bool {
        return index < self.text.len and self.text[index] == '"';
    }
};

test "next" {
    const Case = struct {
        name: []const u8,
        text: []const u8,
        separator: u8 = ',',
        expected: []const Field,
    };

    const cases = [_]Case{
        .{
            .name = "ok_plain",
            .text = "a,b,c",
            .expected = &.{
                .{ .text = "a" },
                .{ .text = "b" },
                .{ .text = "c" },
            },
        },
        .{
            .name = "ok_semicolon",
            .text = "a;b,c",
            .separator = ';',
            .expected = &.{
                .{ .text = "a" },
                .{ .text = "b,c" },
            },
        },
        .{
            .name = "ok_quoted_with_separator",
            .text = "\"Paris, France\",x",
            .expected = &.{
                .{ .text = "Paris, France" },
                .{ .text = "x" },
            },
        },
        .{
            .name = "ok_escaped_quotes",
            .text = "\"he said \"\"yes\"\"\",b",
            .expected = &.{
                .{ .text = "he said \"\"yes\"\"", .has_escaped_quotes = true },
                .{ .text = "b" },
            },
        },
        .{
            .name = "ok_newline_in_quotes",
            .text = "\"x\ny\",z",
            .expected = &.{
                .{ .text = "x\ny" },
                .{ .text = "z" },
            },
        },
        .{
            .name = "ok_quoted_last",
            .text = "a,\"b\"",
            .expected = &.{
                .{ .text = "a" },
                .{ .text = "b" },
            },
        },
        .{
            .name = "ok_quoted_empty",
            .text = "\"\",b",
            .expected = &.{
                .{ .text = "" },
                .{ .text = "b" },
            },
        },
        .{
            .name = "ok_empty_middle",
            .text = "a,,b",
            .expected = &.{
                .{ .text = "a" },
                .{ .text = "" },
                .{ .text = "b" },
            },
        },
        .{
            .name = "ok_trailing_separator",
            .text = "a,",
            .expected = &.{
                .{ .text = "a" },
                .{ .text = "" },
            },
        },
        .{
            .name = "ok_quoted_then_trailing_separator",
            .text = "\"a\",",
            .expected = &.{
                .{ .text = "a" },
                .{ .text = "" },
            },
        },
        .{
            .name = "ok_empty_text",
            .text = "",
            .expected = &.{
                .{ .text = "" },
            },
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var fields: Fields = .{ .text = case.text, .separator = case.separator };
        for (case.expected) |expected| {
            const field = (try fields.next()).?;
            try std.testing.expectEqualStrings(expected.text, field.text);
            try std.testing.expectEqual(expected.has_escaped_quotes, field.has_escaped_quotes);
        }
        try std.testing.expect(try fields.next() == null);
    }
}

test "next fails" {
    const Case = struct {
        name: []const u8,
        text: []const u8,
        expected: CsvError,
    };

    const cases = [_]Case{
        .{
            .name = "err_char_after_quote",
            .text = "\"abc\"x,d",
            .expected = error.UnexpectedCharAfterQuote,
        },
        .{
            .name = "err_unterminated_quote",
            .text = "\"abc",
            .expected = error.UnterminatedQuote,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var fields: Fields = .{ .text = case.text, .separator = ',' };
        try std.testing.expectError(case.expected, fields.next());
    }
}
