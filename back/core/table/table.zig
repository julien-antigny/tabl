const Diagnostics = @import("../diagnostic.zig").Diagnostics;
const Header = @import("header.zig").Header;
const TableError = @import("errors.zig").TableError;

/// How a table compares with the source it was imported from.
pub const Freshness = enum {
    /// The source has not changed since the import.
    fresh,
    /// The source has changed since the import: the table is outdated.
    stale,
    /// The source no longer exists: the table is all that is left.
    source_missing,
};

/// A table already imported, where any cell can be read directly.
///
/// The table is opened on the first call to `header`, `rowCount` or
/// `freshness`: that call may fail, and later ones return the same answer.
///
/// The table does not own its lifecycle: whoever created the adapter
/// behind it opens and closes the underlying resources.
pub const Table = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        header: *const fn (ptr: *anyopaque, diagnostics: *Diagnostics) TableError!Header,
        rowCount: *const fn (ptr: *anyopaque, diagnostics: *Diagnostics) TableError!u32,
        value: *const fn (ptr: *anyopaque, row: u32, column: usize) []const u8,
        freshness: *const fn (ptr: *anyopaque, diagnostics: *Diagnostics) TableError!Freshness,
    };

    /// Returns the column names, in order.
    ///
    /// The names stay valid as long as the table exists.
    /// On error, at least one entry is pushed onto `diagnostics`.
    pub fn header(self: Table, diagnostics: *Diagnostics) TableError!Header {
        return self.vtable.header(self.ptr, diagnostics);
    }

    /// Returns the number of rows. Rows are numbered from 0 to `rowCount() - 1`.
    ///
    /// On error, at least one entry is pushed onto `diagnostics`.
    pub fn rowCount(self: Table, diagnostics: *Diagnostics) TableError!u32 {
        return self.vtable.rowCount(self.ptr, diagnostics);
    }

    /// Returns the text of one cell. An empty cell returns an empty text.
    ///
    /// `header` or `rowCount` must have succeeded before: `value` cannot fail.
    /// `row` must be below `rowCount()` and `column` below the number of
    /// names in the header: any other call is a programming error.
    /// The text stays valid as long as the table exists.
    pub fn value(self: Table, row: u32, column: usize) []const u8 {
        return self.vtable.value(self.ptr, row, column);
    }

    /// Tells whether the source has changed since the import.
    ///
    /// An outdated table can still be read: deciding what to do is up to the caller.
    /// On error, at least one entry is pushed onto `diagnostics`.
    pub fn freshness(self: Table, diagnostics: *Diagnostics) TableError!Freshness {
        return self.vtable.freshness(self.ptr, diagnostics);
    }
};
