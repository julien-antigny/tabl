const std = @import("std");

pub const Error = error{
    UnterminatedQuote,
};

pub const Record = struct {
    text: []const u8,
    line: u64,
};

pub const Records = struct {
    bytes: []const u8,
    position: usize = 0,
    line: u64 = 1,

    pub fn next(self: *Records) Error!?Record {
        while (self.position < self.bytes.len and
            isLineEnd(self.bytes[self.position]))
        {
            if (self.bytes[self.position] == '\n') self.line += 1;
            self.position += 1;
        }

        if (self.position == self.bytes.len) return null;

        const start = self.position;
        const start_line = self.line;
        var in_quotes = false;

        var index = start;
        while (index < self.bytes.len) : (index += 1) {
            switch (self.bytes[index]) {
                '"' => in_quotes = !in_quotes,
                '\n' => {
                    self.line += 1;
                    if (!in_quotes) {
                        self.position = index + 1;
                        return .{
                            .text = withoutCarriageReturn(
                                self.bytes[start..index],
                            ),
                            .line = start_line,
                        };
                    }
                },
                else => {},
            }
        }

        if (in_quotes) return error.UnterminatedQuote;

        self.position = self.bytes.len;
        return .{
            .text = withoutCarriageReturn(
                self.bytes[start..],
            ),
            .line = start_line,
        };
    }
};

fn isLineEnd(byte: u8) bool {
    return byte == '\n' or byte == '\r';
}

fn withoutCarriageReturn(input: []const u8) []const u8 {
    if (input.len == 0) {
        return input;
    }

    if (input[input.len - 1] == '\r') {
        return input[0 .. input.len - 1];
    }

    return input;
}

test "next" {
    const Case = struct {
        name: []const u8,
        bytes: []const u8,
        expected: []const Record,
    };

    const cases = [_]Case{
        .{
            .name = "ok_two_records",
            .bytes = "a,b\nc,d\n",
            .expected = &.{
                .{ .text = "a,b", .line = 1 },
                .{ .text = "c,d", .line = 2 },
            },
        },
        .{
            .name = "ok_last_without_newline",
            .bytes = "a\nb",
            .expected = &.{
                .{ .text = "a", .line = 1 },
                .{ .text = "b", .line = 2 },
            },
        },
        .{
            .name = "ok_windows_line_endings",
            .bytes = "a\r\nb\r\n",
            .expected = &.{
                .{ .text = "a", .line = 1 },
                .{ .text = "b", .line = 2 },
            },
        },
        .{
            .name = "ok_newline_in_quotes",
            .bytes = "\"x\ny\",z\nw",
            .expected = &.{
                .{ .text = "\"x\ny\",z", .line = 1 },
                .{ .text = "w", .line = 3 },
            },
        },
        .{
            .name = "ok_escaped_quotes",
            .bytes = "\"he said \"\"yes\"\"\"\nb",
            .expected = &.{
                .{ .text = "\"he said \"\"yes\"\"\"", .line = 1 },
                .{ .text = "b", .line = 2 },
            },
        },
        .{
            .name = "ok_empty_line_skipped",
            .bytes = "a\n\nb",
            .expected = &.{
                .{ .text = "a", .line = 1 },
                .{ .text = "b", .line = 3 },
            },
        },
        .{
            .name = "ok_empty",
            .bytes = "",
            .expected = &.{},
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var records: Records = .{ .bytes = case.bytes };
        for (case.expected) |expected| {
            const record = (try records.next()).?;
            try std.testing.expectEqualStrings(expected.text, record.text);
            try std.testing.expectEqual(expected.line, record.line);
        }
        try std.testing.expect(try records.next() == null);
    }
}

test "next fails on an unterminated quote" {
    var records: Records = .{ .bytes = "a\n\"b" };
    _ = try records.next();
    try std.testing.expectError(error.UnterminatedQuote, records.next());
}
