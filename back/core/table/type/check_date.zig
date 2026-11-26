const std = @import("std");
const isDigits = @import("check_number.zig").isDigits;

/// The date formats recognized, all 10 characters long.
/// Declared in order of preference: when several formats fit every value
/// of a column, inference picks the first one.
pub const DateFormat = enum {
    year_month_day_dash,
    day_month_year_slash,
    day_month_year_dash,
    day_month_year_dot,
    year_month_day_slash,
    month_day_year_slash,

    const Layout = struct {
        year: usize,
        month: usize,
        day: usize,
        separator: u8,
    };

    fn layout(self: DateFormat) Layout {
        return switch (self) {
            .year_month_day_dash => .{
                .year = 0,
                .month = 5,
                .day = 8,
                .separator = '-',
            },
            .year_month_day_slash => .{
                .year = 0,
                .month = 5,
                .day = 8,
                .separator = '/',
            },
            .day_month_year_slash => .{
                .day = 0,
                .month = 3,
                .year = 6,
                .separator = '/',
            },
            .day_month_year_dash => .{
                .day = 0,
                .month = 3,
                .year = 6,
                .separator = '-',
            },
            .day_month_year_dot => .{
                .day = 0,
                .month = 3,
                .year = 6,
                .separator = '.',
            },
            .month_day_year_slash => .{
                .month = 0,
                .day = 3,
                .year = 6,
                .separator = '/',
            },
        };
    }
};

pub fn isDateText(text: []const u8, format: DateFormat) bool {
    if (text.len != 10) return false;
    const layout = format.layout();

    const first_separator: usize = if (layout.year == 0) 4 else 2;
    const second_separator = first_separator + 3;
    if (text[first_separator] != layout.separator) return false;
    if (text[second_separator] != layout.separator) return false;

    const year = numberOf(text[layout.year .. layout.year + 4]) orelse return false;
    const month = numberOf(text[layout.month .. layout.month + 2]) orelse return false;
    const day = numberOf(text[layout.day .. layout.day + 2]) orelse return false;

    if (month < 1 or month > 12) return false;
    const days_in_month = std.time.epoch.getDaysInMonth(
        year,
        @fromBackingInt(@intCast(month)),
    );
    return day >= 1 and day <= days_in_month;
}

fn numberOf(digits: []const u8) ?u16 {
    if (!isDigits(digits)) return null;
    return std.fmt.parseInt(u16, digits, 10) catch null;
}

test "isDateText" {
    const Case = struct {
        name: []const u8,
        text: []const u8,
        format: DateFormat,
        expected: bool,
    };

    const cases = [_]Case{
        .{
            .name = "ok_year_month_day_dash",
            .text = "2024-03-15",
            .format = .year_month_day_dash,
            .expected = true,
        },
        .{
            .name = "ok_year_month_day_slash",
            .text = "2024/03/15",
            .format = .year_month_day_slash,
            .expected = true,
        },
        .{
            .name = "ok_day_month_year_slash",
            .text = "15/03/2024",
            .format = .day_month_year_slash,
            .expected = true,
        },
        .{
            .name = "ok_day_month_year_dash",
            .text = "15-03-2024",
            .format = .day_month_year_dash,
            .expected = true,
        },
        .{
            .name = "ok_day_month_year_dot",
            .text = "15.03.2024",
            .format = .day_month_year_dot,
            .expected = true,
        },
        .{
            .name = "ok_month_day_year_slash",
            .text = "03/15/2024",
            .format = .month_day_year_slash,
            .expected = true,
        },
        .{
            .name = "ok_leap_day",
            .text = "29/02/2024",
            .format = .day_month_year_slash,
            .expected = true,
        },
        .{
            .name = "error_not_a_leap_year",
            .text = "29/02/2023",
            .format = .day_month_year_slash,
            .expected = false,
        },
        .{
            .name = "error_day_31_in_april",
            .text = "31/04/2024",
            .format = .day_month_year_slash,
            .expected = false,
        },
        .{
            .name = "error_day_zero",
            .text = "00/03/2024",
            .format = .day_month_year_slash,
            .expected = false,
        },
        .{
            .name = "error_month_13",
            .text = "15/13/2024",
            .format = .day_month_year_slash,
            .expected = false,
        },
        .{
            .name = "error_day_first_read_month_first",
            .text = "15/03/2024",
            .format = .month_day_year_slash,
            .expected = false,
        },
        .{
            .name = "error_wrong_separator",
            .text = "15-03-2024",
            .format = .day_month_year_slash,
            .expected = false,
        },
        .{
            .name = "error_mixed_separators",
            .text = "15/03-2024",
            .format = .day_month_year_slash,
            .expected = false,
        },
        .{
            .name = "error_too_short",
            .text = "5/03/2024",
            .format = .day_month_year_slash,
            .expected = false,
        },
        .{
            .name = "error_letters",
            .text = "aa/03/2024",
            .format = .day_month_year_slash,
            .expected = false,
        },
        .{
            .name = "error_sign",
            .text = "+5/03/2024",
            .format = .day_month_year_slash,
            .expected = false,
        },
        .{
            .name = "error_empty",
            .text = "",
            .format = .day_month_year_slash,
            .expected = false,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqual(
            case.expected,
            isDateText(case.text, case.format),
        );
    }
}
