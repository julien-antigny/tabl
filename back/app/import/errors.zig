const std = @import("std");
const TableError = @import("../../core/table/errors.zig").TableError;

pub const ImportError = TableError || std.Io.Cancelable || error{
    /// A value after the sample does not fit the type inferred from it.
    TypeMismatch,
};
