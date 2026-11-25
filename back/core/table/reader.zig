const Diagnostics = @import("../diagnostic.zig").Diagnostics;
const Header = @import("header.zig").Header;
const Row = @import("row.zig").Row;
const TableError = @import("errors.zig").TableError;

/// Reads a table once, from its first row to its last.
///
/// The reader does not own its lifecycle: whoever created the adapter
/// behind it opens and closes the underlying resources.
pub const Reader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        header: *const fn (
            ptr: *anyopaque,
            diagnostics: *Diagnostics,
        ) TableError!Header,
        next: *const fn (
            ptr: *anyopaque,
            diagnostics: *Diagnostics,
        ) TableError!?Row,
    };

    /// Returns the column names.
    ///
    /// The names stay valid as long as the reader exists.
    /// On error, at least one entry is pushed onto `diagnostics`.
    pub fn header(self: Reader, diagnostics: *Diagnostics) TableError!Header {
        return self.vtable.header(self.ptr, diagnostics);
    }

    /// Returns the next row, or null once every row has been read.
    ///
    /// The row stays valid until the next call to `next`: copy it to keep it.
    /// It always has as many values as the header has names; a row that does
    /// not is reported as `Malformed`.
    /// Calling `header` first is not required.
    /// On error, at least one entry is pushed onto `diagnostics`.
    pub fn next(self: Reader, diagnostics: *Diagnostics) TableError!?Row {
        return self.vtable.next(self.ptr, diagnostics);
    }
};
