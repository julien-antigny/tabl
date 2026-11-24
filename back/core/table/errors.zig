pub const TableError = error{
    NotFound,
    Unreadable,
    Malformed,
    OutOfMemory,
};
