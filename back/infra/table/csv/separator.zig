const std = @import("std");

pub const Separator = enum(u8) {
    comma = ',',
    semicolon = ';',
};

pub fn detect(header: []const u8) ?Separator {
    var in_quotes = false;
    var commas: usize = 0;
    var semicolons: usize = 0;

    for (header) |byte| {
        if (byte == '"') {
            in_quotes = !in_quotes;
        }

        if (!in_quotes) {
            switch (byte) {
                ',' => commas += 1,
                ';' => semicolons += 1,
                else => {},
            }
        }
    }

    if (commas > semicolons) return .comma;
    if (semicolons > commas) return .semicolon;
    return null;
}

test "detect" {
    const Case = struct {
        name: []const u8,
        header: []const u8,
        expected: ?Separator,
    };

    const cases = [_]Case{
        .{
            .name = "ok_comma",
            .header = "name,city,age",
            .expected = .comma,
        },
        .{
            .name = "ok_semicolon",
            .header = "name;city;age",
            .expected = .semicolon,
        },
        .{
            .name = "ok_more_semicolons_than_commas",
            .header = "name;city, country;age",
            .expected = .semicolon,
        },
        .{
            .name = "ok_quoted_comma_ignored",
            .header = "\"last, first\";city",
            .expected = .semicolon,
        },
        .{
            .name = "ok_apostrophe_is_not_a_quote",
            .header = "user's name;city, country;code",
            .expected = .semicolon,
        },
        .{
            .name = "undecided_single_column",
            .header = "name",
            .expected = null,
        },
        .{
            .name = "undecided_tie",
            .header = "a,b;c",
            .expected = null,
        },
        .{
            .name = "undecided_empty",
            .header = "",
            .expected = null,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqual(case.expected, detect(case.header));
    }
}
