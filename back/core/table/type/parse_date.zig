const std = @import("std");
const isDigits = @import("parse_number.zig").isDigits;

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

/// Reads a date written in `format`, as a number of days since 1970-01-01
/// (negative before). Returns null when the text does not follow the format
/// or is not a real day of the calendar.
pub fn parseDate(text: []const u8, format: DateFormat) ?i32 {
    if (text.len != 10) return null;
    const layout = format.layout();

    const first_separator: usize = if (layout.year == 0) 4 else 2;
    const second_separator = first_separator + 3;
    if (text[first_separator] != layout.separator) return null;
    if (text[second_separator] != layout.separator) return null;

    const year = numberOf(text[layout.year .. layout.year + 4]) orelse return null;
    const month = numberOf(text[layout.month .. layout.month + 2]) orelse return null;
    const day = numberOf(text[layout.day .. layout.day + 2]) orelse return null;

    if (month < 1 or month > 12) return null;
    const days_in_month = std.time.epoch.getDaysInMonth(
        year,
        @fromBackingInt(@intCast(month)),
    );
    if (day < 1 or day > days_in_month) return null;

    return daysSince1970(year, month, day);
}

fn numberOf(digits: []const u8) ?u16 {
    if (!isDigits(digits)) return null;
    return std.fmt.parseInt(u16, digits, 10) catch null;
}

/// Counts the days from 1970-01-01 to a valid date.
/// Algorithm `days_from_civil` by Howard Hinnant: the year is shifted to start
/// in March, so that February, the only irregular month, comes last.
fn daysSince1970(year: u16, month: u16, day: u16) i32 {
    const shifted_year: i32 = if (month <= 2) @as(i32, year) - 1 else year;
    const era = @divFloor(shifted_year, 400);
    const year_of_era = shifted_year - era * 400;
    const month_from_march: i32 = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * month_from_march + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

test "parseDate" {
    const Case = struct {
        name: []const u8,
        text: []const u8,
        format: DateFormat,
        expected: ?i32,
    };

    const cases = [_]Case{
        .{
            .name = "ok_first_day_of_1970",
            .text = "1970-01-01",
            .format = .year_month_day_dash,
            .expected = 0,
        },
        .{
            .name = "ok_day_before_1970",
            .text = "1969-12-31",
            .format = .year_month_day_dash,
            .expected = -1,
        },
        .{
            .name = "ok_march_after_leap_year_2000",
            .text = "2000-03-01",
            .format = .year_month_day_dash,
            .expected = 11017,
        },
        .{
            .name = "ok_first_year",
            .text = "0001-01-01",
            .format = .year_month_day_dash,
            .expected = -719162,
        },
        .{
            .name = "ok_last_year",
            .text = "9999-12-31",
            .format = .year_month_day_dash,
            .expected = 2932896,
        },
        .{
            .name = "ok_year_month_day_dash",
            .text = "2024-03-15",
            .format = .year_month_day_dash,
            .expected = 19797,
        },
        .{
            .name = "ok_year_month_day_slash",
            .text = "2024/03/15",
            .format = .year_month_day_slash,
            .expected = 19797,
        },
        .{
            .name = "ok_day_month_year_slash",
            .text = "15/03/2024",
            .format = .day_month_year_slash,
            .expected = 19797,
        },
        .{
            .name = "ok_day_month_year_dash",
            .text = "15-03-2024",
            .format = .day_month_year_dash,
            .expected = 19797,
        },
        .{
            .name = "ok_day_month_year_dot",
            .text = "15.03.2024",
            .format = .day_month_year_dot,
            .expected = 19797,
        },
        .{
            .name = "ok_month_day_year_slash",
            .text = "03/15/2024",
            .format = .month_day_year_slash,
            .expected = 19797,
        },
        .{
            .name = "ok_leap_day",
            .text = "29/02/2024",
            .format = .day_month_year_slash,
            .expected = 19782,
        },
        .{
            .name = "error_not_a_leap_year",
            .text = "29/02/2023",
            .format = .day_month_year_slash,
            .expected = null,
        },
        .{
            .name = "error_day_31_in_april",
            .text = "31/04/2024",
            .format = .day_month_year_slash,
            .expected = null,
        },
        .{
            .name = "error_day_zero",
            .text = "00/03/2024",
            .format = .day_month_year_slash,
            .expected = null,
        },
        .{
            .name = "error_month_13",
            .text = "15/13/2024",
            .format = .day_month_year_slash,
            .expected = null,
        },
        .{
            .name = "error_day_first_read_month_first",
            .text = "15/03/2024",
            .format = .month_day_year_slash,
            .expected = null,
        },
        .{
            .name = "error_wrong_separator",
            .text = "15-03-2024",
            .format = .day_month_year_slash,
            .expected = null,
        },
        .{
            .name = "error_mixed_separators",
            .text = "15/03-2024",
            .format = .day_month_year_slash,
            .expected = null,
        },
        .{
            .name = "error_too_short",
            .text = "5/03/2024",
            .format = .day_month_year_slash,
            .expected = null,
        },
        .{
            .name = "error_letters",
            .text = "aa/03/2024",
            .format = .day_month_year_slash,
            .expected = null,
        },
        .{
            .name = "error_sign",
            .text = "+5/03/2024",
            .format = .day_month_year_slash,
            .expected = null,
        },
        .{
            .name = "error_empty",
            .text = "",
            .format = .day_month_year_slash,
            .expected = null,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqual(
            case.expected,
            parseDate(case.text, case.format),
        );
    }
}
