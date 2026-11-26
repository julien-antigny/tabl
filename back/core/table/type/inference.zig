const std = @import("std");
const Type = @import("type.zig").Type;
const ColumnType = @import("type.zig").ColumnType;
const DecimalMark = @import("type.zig").DecimalMark;
const parse_number = @import("parse_number.zig");
const parse_boolean = @import("parse_boolean.zig");
const parse_date = @import("parse_date.zig");
const DateFormat = parse_date.DateFormat;
const Value = @import("../value.zig").Value;

pub const TypeInference = struct {
    candidates: []Candidates,
    decimal_mark: DecimalMark,

    /// `candidates` has one entry per column, `decimal_mark` is the one
    /// used by the decimals of the whole table.
    pub fn new(candidates: []Candidates, decimal_mark: DecimalMark) TypeInference {
        return .{ .candidates = candidates, .decimal_mark = decimal_mark };
    }

    /// Narrows the candidates of each column with one row of the source.
    /// The values come straight from the source: only `.empty` or `.text`,
    /// any other value is a programming error.
    pub fn observe(self: TypeInference, values: []const Value) void {
        for (values, self.candidates) |value, *candidates| {
            switch (value) {
                .empty => {},
                .text => |text| candidates.observe(text, self.decimal_mark),
                .integer, .decimal, .boolean, .date => unreachable,
            }
        }
    }

    /// Writes the type chosen for each column into `types`,
    /// which must have one entry per column.
    pub fn result(self: TypeInference, types: []ColumnType) void {
        for (self.candidates, types) |candidates, *column_type| {
            column_type.* = candidates.result();
        }
    }
};

/// What a column can still be, given the values observed so far.
pub const Candidates = struct {
    types: std.EnumSet(Type) = .full,
    date_formats: std.EnumSet(DateFormat) = .full,
    seen: bool = false,

    fn observe(
        self: *Candidates,
        text: []const u8,
        decimal_mark: DecimalMark,
    ) void {
        self.seen = true;

        const is_integer = self.types.contains(.integer) and
            parse_number.parseInteger(text) != null;

        if (!is_integer) {
            self.types.remove(.integer);
        }

        if (!is_integer and self.types.contains(.decimal) and
            parse_number.parseDecimal(text, decimal_mark) == null)
        {
            self.types.remove(.decimal);
        }

        if (self.types.contains(.boolean) and
            parse_boolean.parseBoolean(text) == null)
        {
            self.types.remove(.boolean);
        }

        for (std.enums.values(DateFormat)) |format| {
            if (self.date_formats.contains(format) and
                parse_date.parseDate(text, format) == null)
            {
                self.date_formats.remove(format);
            }
        }
        if (self.date_formats.count() == 0) {
            self.types.remove(.date);
        }
    }

    fn result(self: Candidates) ColumnType {
        if (!self.seen) return .text;

        var types = self.types.iterator();
        const first = types.next() orelse return .text;
        return switch (first) {
            .integer => .integer,
            .decimal => .decimal,
            .boolean => .boolean,
            .date => {
                var formats = self.date_formats.iterator();
                return .{ .date = formats.next().? };
            },
            .text => .text,
        };
    }
};

test {
    _ = parse_number;
    _ = parse_boolean;
    _ = parse_date;
}

test "observe" {
    const Case = struct {
        name: []const u8,
        rows: []const []const Value,
        decimal_mark: DecimalMark = .point,
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
                &.{ .{ .text = "1" }, .{ .text = "-2" } },
                &.{ .{ .text = "30" }, .{ .text = "+4" } },
            },
            .expected = &.{
                .{
                    .types = .initMany(&.{ .integer, .decimal, .text }),
                    .date_formats = .empty,
                    .seen = true,
                },
                .{
                    .types = .initMany(&.{ .integer, .decimal, .text }),
                    .date_formats = .empty,
                    .seen = true,
                },
            },
        },
        .{
            .name = "ok_decimal_removes_integer",
            .rows = &.{
                &.{ .{ .text = "1" }, .{ .text = "1.5" } },
                &.{ .{ .text = "2" }, .{ .text = "3" } },
            },
            .expected = &.{
                .{
                    .types = .initMany(&.{ .integer, .decimal, .text }),
                    .date_formats = .empty,
                    .seen = true,
                },
                .{
                    .types = .initMany(&.{ .decimal, .text }),
                    .date_formats = .empty,
                    .seen = true,
                },
            },
        },
        .{
            .name = "ok_comma_decimals",
            .rows = &.{
                &.{ .{ .text = "1,5" }, .{ .text = "1.5" } },
                &.{ .{ .text = "2" }, .{ .text = "2" } },
            },
            .decimal_mark = .comma,
            .expected = &.{
                .{
                    .types = .initMany(&.{ .decimal, .text }),
                    .date_formats = .empty,
                    .seen = true,
                },
                .{
                    .types = .initOne(.text),
                    .date_formats = .empty,
                    .seen = true,
                },
            },
        },
        .{
            .name = "ok_booleans",
            .rows = &.{
                &.{ .{ .text = "true" }, .{ .text = "TRUE" } },
                &.{ .{ .text = "False" }, .{ .text = "x" } },
            },
            .expected = &.{
                .{
                    .types = .initMany(&.{ .boolean, .text }),
                    .date_formats = .empty,
                    .seen = true,
                },
                .{
                    .types = .initOne(.text),
                    .date_formats = .empty,
                    .seen = true,
                },
            },
        },
        .{
            .name = "ok_dates_keep_formats_that_fit",
            .rows = &.{
                &.{ .{ .text = "15/03/2024" }, .{ .text = "03/04/2024" } },
                &.{ .{ .text = "01/02/2024" }, .{ .text = "04/03/2024" } },
            },
            .expected = &.{
                .{
                    .types = .initMany(&.{ .date, .text }),
                    .date_formats = .initOne(.day_month_year_slash),
                    .seen = true,
                },
                .{
                    .types = .initMany(&.{ .date, .text }),
                    .date_formats = .initMany(
                        &.{ .day_month_year_slash, .month_day_year_slash },
                    ),
                    .seen = true,
                },
            },
        },
        .{
            .name = "ok_two_date_formats_remove_date",
            .rows = &.{
                &.{ .{ .text = "15/03/2024" }, .{ .text = "2024-03-15" } },
                &.{ .{ .text = "2024-03-15" }, .{ .text = "2024-03-16" } },
            },
            .expected = &.{
                .{
                    .types = .initOne(.text),
                    .date_formats = .empty,
                    .seen = true,
                },
                .{
                    .types = .initMany(&.{ .date, .text }),
                    .date_formats = .initOne(.year_month_day_dash),
                    .seen = true,
                },
            },
        },
        .{
            .name = "ok_removed_stays_removed",
            .rows = &.{
                &.{ .{ .text = "x" }, .{ .text = "1" } },
                &.{ .{ .text = "2" }, .{ .text = "2" } },
            },
            .expected = &.{
                .{
                    .types = .initOne(.text),
                    .date_formats = .empty,
                    .seen = true,
                },
                .{
                    .types = .initMany(&.{ .integer, .decimal, .text }),
                    .date_formats = .empty,
                    .seen = true,
                },
            },
        },
        .{
            .name = "ok_empty_values_ignored",
            .rows = &.{
                &.{ .{ .text = "1" }, .empty },
                &.{ .empty, .empty },
            },
            .expected = &.{
                .{
                    .types = .initMany(&.{ .integer, .decimal, .text }),
                    .date_formats = .empty,
                    .seen = true,
                },
                .{},
            },
        },
        .{
            .name = "ok_empty_text_is_a_value",
            .rows = &.{
                &.{ .{ .text = "1" }, .{ .text = "" } },
            },
            .expected = &.{
                .{
                    .types = .initMany(&.{ .integer, .decimal, .text }),
                    .date_formats = .empty,
                    .seen = true,
                },
                .{
                    .types = .initOne(.text),
                    .date_formats = .empty,
                    .seen = true,
                },
            },
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var candidates = [_]Candidates{ .{}, .{} };
        const inference: TypeInference = .new(&candidates, case.decimal_mark);
        for (case.rows) |row| {
            inference.observe(row);
        }

        try std.testing.expectEqualDeep(case.expected, &candidates);
    }
}

test "result" {
    const Case = struct {
        name: []const u8,
        candidates: Candidates,
        expected: ColumnType,
    };

    const cases = [_]Case{
        .{
            .name = "ok_nothing_seen",
            .candidates = .{},
            .expected = .text,
        },
        .{
            .name = "ok_integer_before_decimal",
            .candidates = .{
                .types = .initMany(&.{ .integer, .decimal, .text }),
                .date_formats = .empty,
                .seen = true,
            },
            .expected = .integer,
        },
        .{
            .name = "ok_decimal",
            .candidates = .{
                .types = .initMany(&.{ .decimal, .text }),
                .date_formats = .empty,
                .seen = true,
            },
            .expected = .decimal,
        },
        .{
            .name = "ok_boolean",
            .candidates = .{
                .types = .initMany(&.{ .boolean, .text }),
                .date_formats = .empty,
                .seen = true,
            },
            .expected = .boolean,
        },
        .{
            .name = "ok_date_day_first_before_month_first",
            .candidates = .{
                .types = .initMany(&.{ .date, .text }),
                .date_formats = .initMany(
                    &.{ .day_month_year_slash, .month_day_year_slash },
                ),
                .seen = true,
            },
            .expected = .{ .date = .day_month_year_slash },
        },
        .{
            .name = "ok_text",
            .candidates = .{
                .types = .initOne(.text),
                .date_formats = .empty,
                .seen = true,
            },
            .expected = .text,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var candidates = [_]Candidates{case.candidates};
        var types: [1]ColumnType = undefined;
        const inference: TypeInference = .new(&candidates, .point);
        inference.result(&types);

        try std.testing.expectEqual(case.expected, types[0]);
    }
}
