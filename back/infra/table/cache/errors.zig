pub const CacheError = error{
    NotACache,
    UnsupportedVersion,
    InvalidMeta,
    InvalidOffsetWidth,
    PathIsNotAbsolute,
    SizeMismatch,
    LastEndMismatch,
    TooManyRows,
    Incomplete,
    MissingColumnFile,
    OutOfMemory,
};
