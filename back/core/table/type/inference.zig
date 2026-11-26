const std = @import("std");
const Type = @import("type.zig").Type;
const check_number = @import("check_number.zig");
const check_boolean = @import("check_boolean.zig");
const check_date = @import("check_date.zig");
const DateFormat = check_date.DateFormat;

pub const TypeInference = struct {
    candidates: []Candidates,

    pub fn inference(self: TypeInference, inputs: []const []const u8) void {
        for (inputs, self.candidates) |value, *candidates| {
            candidates.observe(value);
        }
    }
};

/// What a column can still be, given the values observed so far.
pub const Candidates = struct {
    types: std.EnumSet(Type) = .full,
    date_formats: std.EnumSet(DateFormat) = .full,

    fn observe(self: *Candidates, text: []const u8) void {
        if (self.types.contains(.integer) and !check_number.isIntegerText(text)) {
            self.types.remove(.integer);
        }

        if (self.types.contains(.decimal) and !check_number.isDecimalText(text)) {
            self.types.remove(.decimal);
        }

        if (self.types.contains(.boolean) and !check_boolean.isBooleanText(text)) {
            self.types.remove(.boolean);
        }

        for (std.enums.values(DateFormat)) |format| {
            if (self.date_formats.contains(format) and !check_date.isDateText(text, format)) {
                self.date_formats.remove(format);
            }
        }
        if (self.date_formats.count() == 0) {
            self.types.remove(.date);
        }
    }
};

test {
    _ = check_number;
    _ = check_boolean;
    _ = check_date;
}

test "inference" {
    const Case = struct {
        name: []const u8,
        rows: []const []const []const u8,
        expected: []const Candidates,
    };

    const cases = [_]Case{
        .{
            .name = "ok_no_rows",
            .rows = &.{},
            .expected = &.{ .{}, .{} },
        },
        .{
            .name = "ok_integers",
            .rows = &.{
                &.{ "1", "-2" },
                &.{ "30", "+4" },
            },
            .expected = &.{
                .{
                    .types = .initMany(&.{ .integer, .decimal, .text }),
                    .date_formats = .empty,
                },
                .{
                    .types = .initMany(&.{ .integer, .decimal, .text }),
                    .date_formats = .empty,
                },
            },
        },
        .{
            .name = "ok_decimal_removes_integer",
            .rows = &.{
                &.{ "1", "1.5" },
                &.{ "2", "3" },
            },
            .expected = &.{
                .{
                    .types = .initMany(&.{ .integer, .decimal, .text }),
                    .date_formats = .empty,
                },
                .{
                    .types = .initMany(&.{ .decimal, .text }),
                    .date_formats = .empty,
                },
            },
        },
        .{
            .name = "ok_booleans",
            .rows = &.{
                &.{ "true", "TRUE" },
                &.{ "False", "x" },
            },
            .expected = &.{
                .{
                    .types = .initMany(&.{ .boolean, .text }),
                    .date_formats = .empty,
                },
                .{ .types = .initOne(.text), .date_formats = .empty },
            },
        },
        .{
            .name = "ok_dates_keep_formats_that_fit",
            .rows = &.{
                &.{ "15/03/2024", "03/04/2024" },
                &.{ "01/02/2024", "04/03/2024" },
            },
            .expected = &.{
                .{
                    .types = .initMany(&.{ .date, .text }),
                    .date_formats = .initOne(.day_month_year_slash),
                },
                .{
                    .types = .initMany(&.{ .date, .text }),
                    .date_formats = .initMany(
                        &.{ .day_month_year_slash, .month_day_year_slash },
                    ),
                },
            },
        },
        .{
            .name = "ok_two_date_formats_remove_date",
            .rows = &.{
                &.{ "15/03/2024", "2024-03-15" },
                &.{ "2024-03-15", "2024-03-16" },
            },
            .expected = &.{
                .{ .types = .initOne(.text), .date_formats = .empty },
                .{
                    .types = .initMany(&.{ .date, .text }),
                    .date_formats = .initOne(.year_month_day_dash),
                },
            },
        },
        .{
            .name = "ok_removed_stays_removed",
            .rows = &.{
                &.{ "x", "1" },
                &.{ "2", "2" },
            },
            .expected = &.{
                .{ .types = .initOne(.text), .date_formats = .empty },
                .{
                    .types = .initMany(&.{ .integer, .decimal, .text }),
                    .date_formats = .empty,
                },
            },
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var candidates = [_]Candidates{ .{}, .{} };
        const inference: TypeInference = .{ .candidates = &candidates };
        for (case.rows) |row| {
            inference.inference(row);
        }

        try std.testing.expectEqualDeep(case.expected, &candidates);
    }
}
