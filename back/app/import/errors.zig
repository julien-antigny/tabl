const TableError = @import("../../core/table/errors.zig").TableError;

pub const ImportError = TableError || error{
    /// A value after the sample does not fit the type inferred from it.
    TypeMismatch,
};
