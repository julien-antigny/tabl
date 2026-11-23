const TableError = @import("../../core/table/errors.zig").TableError;

pub const ScanError = error{
    TableNotFound,
    TableUnreadable,
    TableMalformed,
    OutOfMemory,
};

pub fn fromTable(err: TableError) ScanError {
    return switch (err) {
        error.NotFound => error.TableNotFound,
        error.Unreadable => error.TableUnreadable,
        error.Malformed => error.TableMalformed,
        error.OutOfMemory => error.OutOfMemory,
    };
}
