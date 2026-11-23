pub const ErrorLayer = enum {
    core,
    infra,
    app,
};

pub const ErrorLocation = struct {
    path: []const u8,
    line: ?u64 = null,
};

pub const ErrorDiagnostic = struct {
    layer: ErrorLayer,
    message: []const u8,
    cause: ?*const ErrorDiagnostic = null,
    kind: anyerror,
    location: ?ErrorLocation = null,
};
