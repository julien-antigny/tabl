const Diagnostics = @import("../diagnostic.zig").Diagnostics;
const Header = @import("header.zig").Header;
const RowReader = @import("row_reader.zig").RowReader;
const TableError = @import("errors.zig").TableError;

/// Gives access to a table: its header, and its rows through row readers.
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
        rowReaders: *const fn (
            ptr: *anyopaque,
            count: usize,
            diagnostics: *Diagnostics,
        ) TableError![]const RowReader,
    };

    /// Returns the column names.
    ///
    /// The names stay valid as long as the reader exists.
    /// On error, at least one entry is pushed onto `diagnostics`.
    pub fn header(self: Reader, diagnostics: *Diagnostics) TableError!Header {
        return self.vtable.header(self.ptr, diagnostics);
    }

    /// Returns at most `count` row readers, at least one: each reads a part
    /// of whole rows, and together they give every row, in order.
    /// One row reader reads the whole table; several can be read at the
    /// same time, one per thread.
    ///
    /// Each row reader starts on its first row: call `rowReaders` again to
    /// read the rows again. `count` is at least 1.
    /// The row readers stay valid until the next call to `rowReaders`,
    /// or until the adapter is closed.
    pub fn rowReaders(
        self: Reader,
        count: usize,
        diagnostics: *Diagnostics,
    ) TableError![]const RowReader {
        return self.vtable.rowReaders(self.ptr, count, diagnostics);
    }
};
