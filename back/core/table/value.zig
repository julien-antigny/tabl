pub const Value = union(enum) {
    empty,
    integer: i64,
    decimal: f64,
    boolean: bool,
    date: i32,
    text: []const u8,
};
