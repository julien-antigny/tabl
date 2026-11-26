const std = @import("std");

/// A day of the calendar, and its number of days since 1970-01-01.
///
/// Algorithms `days_from_civil` and `civil_from_days` by Howard Hinnant:
/// the year is shifted to start in March, so that February, the only
/// irregular month, comes last. An era is 400 years, 146097 days.
pub const CalendarDate = struct {
    year: i32,
    month: u8,
    day: u8,

    /// Counts the days from 1970-01-01, negative before.
    /// The date must be a real day of the calendar.
    pub fn toDays(self: CalendarDate) i32 {
        const month: i64 = self.month;
        const shifted_year: i64 = if (month <= 2) @as(i64, self.year) - 1 else self.year;
        const era = @divFloor(shifted_year, 400);
        const year_of_era = shifted_year - era * 400;
        const month_from_march = if (month > 2) month - 3 else month + 9;
        const day_of_year = @divFloor(153 * month_from_march + 2, 5) + self.day - 1;
        const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
            @divFloor(year_of_era, 100) + day_of_year;
        return @intCast(era * 146097 + day_of_era - 719468);
    }

    /// The date that comes `days` days after 1970-01-01, before when negative.
    pub fn fromDays(days: i32) CalendarDate {
        const shifted: i64 = @as(i64, days) + 719468;
        const era = @divFloor(shifted, 146097);
        const day_of_era = shifted - era * 146097;
        const year_of_era = @divFloor(
            day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) -
                @divFloor(day_of_era, 146096),
            365,
        );
        const day_of_year = day_of_era -
            (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
        const month_from_march = @divFloor(5 * day_of_year + 2, 153);
        const day = day_of_year - @divFloor(153 * month_from_march + 2, 5) + 1;
        const month = if (month_from_march < 10) month_from_march + 3 else month_from_march - 9;
        const year = year_of_era + era * 400 + @intFromBool(month <= 2);
        return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
    }
};

test "toDays and fromDays" {
    const Case = struct {
        name: []const u8,
        date: CalendarDate,
        days: i32,
    };

    const cases = [_]Case{
        .{ .name = "ok_first_day_of_1970", .date = .{ .year = 1970, .month = 1, .day = 1 }, .days = 0 },
        .{ .name = "ok_day_before_1970", .date = .{ .year = 1969, .month = 12, .day = 31 }, .days = -1 },
        .{ .name = "ok_leap_day", .date = .{ .year = 2024, .month = 2, .day = 29 }, .days = 19782 },
        .{ .name = "ok_after_leap_day", .date = .{ .year = 2024, .month = 3, .day = 15 }, .days = 19797 },
        .{ .name = "ok_century_leap_year", .date = .{ .year = 2000, .month = 3, .day = 1 }, .days = 11017 },
        .{ .name = "ok_first_year", .date = .{ .year = 1, .month = 1, .day = 1 }, .days = -719162 },
        .{ .name = "ok_last_year", .date = .{ .year = 9999, .month = 12, .day = 31 }, .days = 2932896 },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqual(case.days, case.date.toDays());
        try std.testing.expectEqual(case.date, CalendarDate.fromDays(case.days));
    }
}

test "fromDays gives back every day of four centuries" {
    var days: i32 = -146097 * 2;
    while (days < 146097 * 2) : (days += 1) {
        try std.testing.expectEqual(days, CalendarDate.fromDays(days).toDays());
    }
}
