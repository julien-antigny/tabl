const Value = @import("value.zig").Value;

pub const Row = struct {
    values: []const Value,
};
