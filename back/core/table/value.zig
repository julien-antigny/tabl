pub const Value = union(enum) {
    empty,
    text: []const u8,
};
