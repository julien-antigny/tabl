pub const diagnostic = @import("core/diagnostic.zig");

test {
    _ = @import("infra/table/csv/separator.zig");
    _ = @import("infra/table/csv/records.zig");
    _ = @import("infra/table/csv/fields.zig");
}
