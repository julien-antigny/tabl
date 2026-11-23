pub const diagnostic = @import("core/diagnostic.zig");

test {
    _ = diagnostic;
    _ = @import("core/table/reader.zig");
    _ = @import("app/scan/scan.zig");
    _ = @import("infra/table/csv/separator.zig");
    _ = @import("infra/table/csv/records.zig");
    _ = @import("infra/table/csv/fields.zig");
    _ = @import("infra/table/csv/reader.zig");
}
