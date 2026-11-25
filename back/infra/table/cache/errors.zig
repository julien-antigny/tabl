pub const CacheError = error{
    NotACache,
    UnsupportedVersion,
    InvalidMeta,
    InvalidOffsetWidth,
    PathIsNotAbsolute,
    SizeMismatch,
    MaskSizeMismatch,
    LastEndMismatch,
    TooManyRows,
    Incomplete,
    MissingColumnFile,
    OutOfMemory,
};
