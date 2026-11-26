///  Declared from the most precise to the least:
/// inference picks the first one still possible.
pub const Type = enum {
    integer,
    decimal,
    boolean,
    date,
    text,
};
