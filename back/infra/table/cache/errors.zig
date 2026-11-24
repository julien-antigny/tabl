pub const CacheError = error{
    NotACache,
    UnsupportedVersion,
    InvalidMeta,
    InvalidOffsetWidth,
    PathIsNotAbsolute,
    OutOfMemory,
};
