pub const CacheError = error{
    NotACache,
    UnsupportedVersion,
    InvalidMeta,
    InvalidOffsetWidth,
    PathIsNotAbsolute,
    SizeMismatch,
    DecreasingEnds,
    LastEndMismatch,
    TooManyRows,
    Incomplete,
    MissingColumnFile,
    OutOfMemory,
};
