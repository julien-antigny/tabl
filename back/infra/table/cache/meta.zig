const std = @import("std");
const CacheError = @import("errors.zig").CacheError;

pub const format_name = "tabl-cache";
pub const current_version: u32 = 1;

pub const Source = struct {
    path: []const u8,
    size: u64,
    modified_ns: i64,
};

pub const Column = struct {
    name: []const u8,
    offset_width: u32,
};

pub const Meta = struct {
    format: []const u8,
    version: u32,
    rows: u32,
    source: Source,
    columns: []const Column,
};

pub fn parse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) CacheError!std.json.Parsed(Meta) {
    try identify(allocator, bytes);

    const parsed = std.json.parseFromSlice(Meta, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| return fromJson(err);
    errdefer parsed.deinit();

    try check(parsed.value);
    return parsed;
}

pub fn write(meta: Meta, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try std.json.Stringify.value(meta, .{ .whitespace = .indent_2 }, writer);
    try writer.writeByte('\n');
}

fn identify(allocator: std.mem.Allocator, bytes: []const u8) CacheError!void {
    const Envelope = struct {
        format: []const u8 = "",
        version: ?u32 = null,
    };

    const envelope = std.json.parseFromSlice(Envelope, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| return fromJson(err);
    defer envelope.deinit();

    if (!std.mem.eql(u8, envelope.value.format, format_name)) {
        return CacheError.NotACache;
    }

    const version = envelope.value.version orelse return CacheError.InvalidMeta;
    if (version != current_version) {
        return CacheError.UnsupportedVersion;
    }
}

fn check(meta: Meta) CacheError!void {
    for (meta.columns) |column| {
        if (column.offset_width != 32 and column.offset_width != 64) {
            return CacheError.InvalidOffsetWidth;
        }
    }

    if (!std.fs.path.isAbsolute(meta.source.path)) {
        return CacheError.PathIsNotAbsolute;
    }
}

fn fromJson(err: std.json.ParseError(std.json.Scanner)) CacheError {
    return switch (err) {
        error.OutOfMemory => CacheError.OutOfMemory,
        else => CacheError.InvalidMeta,
    };
}

test "check" {
    const valid: Meta = .{
        .format = format_name,
        .version = current_version,
        .rows = 2,
        .source = .{
            .path = "/data/sales.csv",
            .size = 42,
            .modified_ns = 0,
        },
        .columns = &.{
            .{ .name = "city", .offset_width = 32 },
            .{ .name = "notes", .offset_width = 64 },
        },
    };

    const Case = struct {
        name: []const u8,
        meta: Meta,
        expected: ?CacheError,
    };

    var bad_width = valid;
    bad_width.columns = &.{
        .{ .name = "city", .offset_width = 32 },
        .{ .name = "notes", .offset_width = 16 },
    };

    var no_columns = valid;
    no_columns.columns = &.{};

    var invalid_path = valid;
    invalid_path.source.path = "sales.csv";

    const cases = [_]Case{
        .{
            .name = "ok_valid",
            .meta = valid,
            .expected = null,
        },
        .{
            .name = "ok_no_columns",
            .meta = no_columns,
            .expected = null,
        },
        .{
            .name = "error_invalid_offset_width",
            .meta = bad_width,
            .expected = CacheError.InvalidOffsetWidth,
        },
        .{
            .name = "error_path_is_not_absolute",
            .meta = invalid_path,
            .expected = CacheError.PathIsNotAbsolute,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        if (case.expected) |expected| {
            try std.testing.expectError(expected, check(case.meta));
        } else {
            try check(case.meta);
        }
    }
}

test "parse reads a valid meta" {
    const bytes =
        \\{
        \\  "format": "tabl-cache",
        \\  "version": 1,
        \\  "rows": 2,
        \\  "source": { "path": "/data/sales.csv", "size": 42, "modified_ns": -5 },
        \\  "columns": [
        \\    { "name": "city", "offset_width": 32 },
        \\    { "name": "notes", "offset_width": 64 }
        \\  ]
        \\}
    ;

    const parsed = try parse(std.testing.allocator, bytes);
    defer parsed.deinit();
    const meta = parsed.value;

    try std.testing.expectEqual(2, meta.rows);
    try std.testing.expectEqualStrings("/data/sales.csv", meta.source.path);
    try std.testing.expectEqual(42, meta.source.size);
    try std.testing.expectEqual(-5, meta.source.modified_ns);
    try std.testing.expectEqual(2, meta.columns.len);
    try std.testing.expectEqualStrings("notes", meta.columns[1].name);
    try std.testing.expectEqual(64, meta.columns[1].offset_width);
}

test "parse fails" {
    const Case = struct {
        name: []const u8,
        bytes: []const u8,
        expected: CacheError,
    };

    const cases = [_]Case{
        .{
            .name = "error_not_json",
            .bytes = "hello",
            .expected = CacheError.InvalidMeta,
        },
        .{
            .name = "error_truncated",
            .bytes = "{ \"format\": \"tabl-cache\", \"version\": 1, \"rows\": 2",
            .expected = CacheError.InvalidMeta,
        },
        .{
            .name = "error_format_checked_before_version",
            .bytes = "{ \"format\": \"other\", \"version\": 7 }",
            .expected = CacheError.NotACache,
        },
        .{
            .name = "error_no_format",
            .bytes = "{ \"name\": \"package\", \"version\": 1 }",
            .expected = CacheError.NotACache,
        },
        .{
            .name = "error_no_version",
            .bytes = "{ \"format\": \"tabl-cache\" }",
            .expected = CacheError.InvalidMeta,
        },
        .{
            .name = "error_newer_version_with_new_fields",
            .bytes = "{ \"format\": \"tabl-cache\", \"version\": 2, \"blocks\": 8 }",
            .expected = CacheError.UnsupportedVersion,
        },
        .{
            .name = "error_missing_source",
            .bytes =
            \\{ "format": "tabl-cache", "version": 1, "rows": 0, "columns": [] }
            ,
            .expected = CacheError.InvalidMeta,
        },
        .{
            .name = "error_source_without_size",
            .bytes =
            \\{ "format": "tabl-cache", "version": 1, "rows": 0, "columns": [],
            \\  "source": { "path": "/a.csv", "modified_ns": 0 } }
            ,
            .expected = CacheError.InvalidMeta,
        },
        .{
            .name = "error_size_is_text",
            .bytes =
            \\{ "format": "tabl-cache", "version": 1, "rows": 0, "columns": [],
            \\  "source": { "path": "/a.csv", "size": "abc", "modified_ns": 0 } }
            ,
            .expected = CacheError.InvalidMeta,
        },
        .{
            .name = "error_columns_not_a_list",
            .bytes =
            \\{ "format": "tabl-cache", "version": 1, "rows": 0, "columns": 3,
            \\  "source": { "path": "/a.csv", "size": 0, "modified_ns": 0 } }
            ,
            .expected = CacheError.InvalidMeta,
        },
        .{
            .name = "error_column_without_name",
            .bytes =
            \\{ "format": "tabl-cache", "version": 1, "rows": 0,
            \\  "columns": [ { "offset_width": 32 } ],
            \\  "source": { "path": "/a.csv", "size": 0, "modified_ns": 0 } }
            ,
            .expected = CacheError.InvalidMeta,
        },
        .{
            .name = "error_unknown_field",
            .bytes =
            \\{ "format": "tabl-cache", "version": 1, "rows": 0, "columns": [], "extra": true,
            \\  "source": { "path": "/a.csv", "size": 0, "modified_ns": 0 } }
            ,
            .expected = CacheError.InvalidMeta,
        },
        .{
            .name = "error_too_many_rows",
            .bytes =
            \\{ "format": "tabl-cache", "version": 1, "rows": 4294967296, "columns": [],
            \\  "source": { "path": "/a.csv", "size": 0, "modified_ns": 0 } }
            ,
            .expected = CacheError.InvalidMeta,
        },
        .{
            .name = "error_check_after_parse",
            .bytes =
            \\{ "format": "tabl-cache", "version": 1, "rows": 0,
            \\  "columns": [ { "name": "city", "offset_width": 16 } ],
            \\  "source": { "path": "/a.csv", "size": 0, "modified_ns": 0 } }
            ,
            .expected = CacheError.InvalidOffsetWidth,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectError(
            case.expected,
            parse(std.testing.allocator, case.bytes),
        );
    }
}

test "write then parse gives the same meta" {
    const meta: Meta = .{
        .format = format_name,
        .version = current_version,
        .rows = 3,
        .source = .{
            .path = "/data/sales.csv",
            .size = 1234,
            .modified_ns = 1764001234123456789,
        },
        .columns = &.{
            .{ .name = "city", .offset_width = 32 },
            .{ .name = "say \"hi\"", .offset_width = 64 },
        },
    };

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write(meta, &writer);

    const parsed = try parse(std.testing.allocator, writer.buffered());
    defer parsed.deinit();

    try std.testing.expectEqualDeep(meta, parsed.value);
}
