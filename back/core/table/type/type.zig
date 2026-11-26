const DateFormat = @import("parse_date.zig").DateFormat;

/// Declared from the most precise to the least:
/// inference picks the first one still possible.
pub const Type = enum {
    integer,
    decimal,
    boolean,
    date,
    text,
};

/// The character between the integer part and the fraction of a decimal.
/// The same for the whole table.
pub const DecimalMark = enum {
    point,
    comma,
};

/// The type chosen for a column. A date carries its format,
/// needed to read the values; `std.meta.activeTag` gives the `Type`.
pub const ColumnType = union(Type) {
    integer,
    decimal,
    boolean,
    date: DateFormat,
    text,
};
