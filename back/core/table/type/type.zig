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

/// The type chosen for a column. A date carries its format,
/// needed to read the values; `std.meta.activeTag` gives the `Type`.
pub const ColumnType = union(Type) {
    integer,
    decimal,
    boolean,
    date: DateFormat,
    text,
};
