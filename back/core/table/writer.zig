const Diagnostics = @import("../diagnostic.zig").Diagnostics;
const Header = @import("header.zig").Header;
const Row = @import("row.zig").Row;
const TableError = @import("errors.zig").TableError;
const ColumnType = @import("type/type.zig").ColumnType;

/// Writes a table once, from its header to its last row.
///
/// Calls follow a fixed order: `header` once, then `row` for each row,
/// then `finish` once. Calling them in any other order is a programming error.
///
/// The writer does not own its lifecycle: whoever created the adapter
/// behind it opens and closes the underlying resources.
pub const Writer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        header: *const fn (
            ptr: *anyopaque,
            header: Header,
            types: []const ColumnType,
            diagnostics: *Diagnostics,
        ) TableError!void,
        row: *const fn (
            ptr: *anyopaque,
            row: Row,
            diagnostics: *Diagnostics,
        ) TableError!void,
        finish: *const fn (
            ptr: *anyopaque,
            diagnostics: *Diagnostics,
        ) TableError!void,
    };

    /// Starts the table with its column names and the type of each column.
    ///
    /// `types` has one entry per name. Every value written later in a column
    /// is `.empty` or a value of the column type: `.text` for a text column,
    /// `.integer` for an integer column, and so on.
    /// The names and types only need to stay valid during the call:
    /// the writer copies what it keeps.
    /// On error, at least one entry is pushed onto `diagnostics`.
    pub fn header(
        self: Writer,
        value: Header,
        types: []const ColumnType,
        diagnostics: *Diagnostics,
    ) TableError!void {
        return self.vtable.header(self.ptr, value, types, diagnostics);
    }

    /// Appends one row.
    ///
    /// The row only needs to stay valid during the call, so a row returned
    /// by `Reader.next` can be passed as is.
    /// It must have as many values as the header has names:
    /// passing any other row is a programming error.
    /// On error, at least one entry is pushed onto `diagnostics`.
    pub fn row(
        self: Writer,
        value: Row,
        diagnostics: *Diagnostics,
    ) TableError!void {
        return self.vtable.row(self.ptr, value, diagnostics);
    }

    /// Completes the table.
    ///
    /// The table only exists once `finish` has succeeded: if it is never
    /// called, or fails, readers see no table or refuse it.
    /// On error, at least one entry is pushed onto `diagnostics`.
    pub fn finish(
        self: Writer,
        diagnostics: *Diagnostics,
    ) TableError!void {
        return self.vtable.finish(self.ptr, diagnostics);
    }
};
