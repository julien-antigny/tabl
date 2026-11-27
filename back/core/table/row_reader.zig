const Diagnostics = @import("../diagnostic.zig").Diagnostics;
const Row = @import("row.zig").Row;
const TableError = @import("errors.zig").TableError;

/// Reads one part of the rows of a table, from its first row to its last.
/// It is given by `Reader.rowReaders`.
///
/// Each row reader has its own position: several can be read at the same
/// time, one per thread.
pub const RowReader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (
            ptr: *anyopaque,
            diagnostics: *Diagnostics,
        ) TableError!?Row,
    };

    /// Returns the next row, or null once every row of the part has been read.
    ///
    /// The row stays valid until the next call to `next`: copy it to keep it.
    /// It always has as many values as the header has names; a row that does
    /// not is reported as `Malformed`.
    pub fn next(self: RowReader, diagnostics: *Diagnostics) TableError!?Row {
        return self.vtable.next(self.ptr, diagnostics);
    }
};
