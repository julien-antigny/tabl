const std = @import("std");
const Diagnostics = @import("../../../core/diagnostic.zig").Diagnostics;
const Header = @import("../../../core/table/header.zig").Header;
const table_port = @import("../../../core/table/table.zig");
const Table = table_port.Table;
const Freshness = table_port.Freshness;
const TableError = @import("../../../core/table/errors.zig").TableError;
const Value = @import("../../../core/table/value.zig").Value;
const CacheError = @import("errors.zig").CacheError;
const meta = @import("meta.zig");
const TextColumn = @import("column.zig").TextColumn;

const page_align = std.heap.page_size_min;
const Bytes = []align(page_align) const u8;
const no_bytes: [0]u8 align(page_align) = .{};
const max_meta_size = 1024 * 1024;

const MappedFile = struct {
    file: std.Io.File,
    map: ?std.Io.File.MemoryMap,

    fn bytes(self: MappedFile) Bytes {
        return if (self.map) |map| map.memory else &no_bytes;
    }
};

const FileName = [32]u8;

pub const CacheTable = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    path: []const u8,
    arena: std.heap.ArenaAllocator,
    opened: bool = false,
    open_error: ?anyerror = null,
    cache_dir: ?std.Io.Dir = null,
    parsed: ?std.json.Parsed(meta.Meta) = null,
    names: []const []const u8 = &.{},
    files: []MappedFile = &.{},
    mapped_files: usize = 0,
    columns: []TextColumn = &.{},
    current_file: []const u8 = "",
    current_file_buffer: FileName = undefined,
    location_buffer: [512]u8 = undefined,
    message_buffer: [128]u8 = undefined,

    pub fn new(
        io: std.Io,
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        path: []const u8,
    ) CacheTable {
        return .{
            .io = io,
            .allocator = allocator,
            .dir = dir,
            .path = path,
            .arena = .init(allocator),
        };
    }

    pub fn close(self: *CacheTable) void {
        for (self.files[0..self.mapped_files]) |*mapped| {
            if (mapped.map) |*map| map.destroy(self.io);
            mapped.file.close(self.io);
        }
        if (self.cache_dir) |cache_dir| cache_dir.close(self.io);
        if (self.parsed) |parsed| parsed.deinit();
        self.arena.deinit();
        self.* = .new(self.io, self.allocator, self.dir, self.path);
    }

    pub fn table(self: *CacheTable) Table {
        return .{
            .ptr = self,
            .vtable = &.{
                .header = header,
                .rowCount = rowCount,
                .value = value,
                .freshness = freshness,
            },
        };
    }

    fn header(ptr: *anyopaque, diagnostics: *Diagnostics) TableError!Header {
        const self: *CacheTable = @ptrCast(@alignCast(ptr));
        self.open() catch |err| return self.fail(err, diagnostics);
        return .{ .names = self.names };
    }

    fn rowCount(ptr: *anyopaque, diagnostics: *Diagnostics) TableError!u32 {
        const self: *CacheTable = @ptrCast(@alignCast(ptr));
        self.open() catch |err| return self.fail(err, diagnostics);
        return self.parsed.?.value.rows;
    }

    fn value(ptr: *anyopaque, row: u32, column: usize) Value {
        const self: *CacheTable = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.opened);
        std.debug.assert(column < self.columns.len);
        return self.columns[column].value(row);
    }

    fn freshness(ptr: *anyopaque, diagnostics: *Diagnostics) TableError!Freshness {
        const self: *CacheTable = @ptrCast(@alignCast(ptr));
        self.open() catch |err| return self.fail(err, diagnostics);
        return self.compareWithSource() catch |err| self.fail(err, diagnostics);
    }

    fn open(self: *CacheTable) !void {
        if (self.opened) return;
        if (self.open_error) |err| return err;

        self.load() catch |err| {
            self.open_error = err;
            return err;
        };
        self.opened = true;
    }

    fn load(self: *CacheTable) !void {
        const arena = self.arena.allocator();

        const cache_dir = try self.dir.openDir(self.io, self.path, .{});
        self.cache_dir = cache_dir;

        self.current_file = meta.file_name;
        const meta_bytes = cache_dir.readFileAlloc(
            self.io,
            meta.file_name,
            self.allocator,
            .limited(max_meta_size),
        ) catch |err| switch (err) {
            error.FileNotFound => return CacheError.Incomplete,
            else => return err,
        };
        defer self.allocator.free(meta_bytes);

        self.parsed = try meta.parse(self.allocator, meta_bytes);
        const description = self.parsed.?.value;

        const names = try arena.alloc([]const u8, description.columns.len);
        for (description.columns, names) |column, *name| {
            name.* = column.name;
        }
        self.names = names;

        self.files = try arena.alloc(MappedFile, description.columns.len * 3);
        self.columns = try arena.alloc(TextColumn, description.columns.len);
        for (description.columns, self.columns, 0..) |column, *text_column, index| {
            const ends = try self.mapColumnFile(cache_dir, index, "ends");
            const bytes = try self.mapColumnFile(cache_dir, index, "bytes");
            const empty_mask = try self.mapColumnFile(cache_dir, index, "empty");
            text_column.* = TextColumn.new(
                ends,
                bytes,
                empty_mask,
                column.offset_width,
                description.rows,
            ) catch |err| {
                self.setCurrentFile(index, if (err == error.MaskSizeMismatch) "empty" else "ends");
                return err;
            };
        }
    }

    fn setCurrentFile(self: *CacheTable, index: usize, extension: []const u8) void {
        self.current_file = std.fmt.bufPrint(
            &self.current_file_buffer,
            "{d}.{s}",
            .{ index, extension },
        ) catch unreachable;
    }

    fn mapColumnFile(self: *CacheTable, cache_dir: std.Io.Dir, index: usize, extension: []const u8) !Bytes {
        self.setCurrentFile(index, extension);

        const file = cache_dir.openFile(self.io, self.current_file, .{}) catch |err| switch (err) {
            error.FileNotFound => return CacheError.MissingColumnFile,
            else => return err,
        };
        errdefer file.close(self.io);

        const length = try file.length(self.io);
        const map: ?std.Io.File.MemoryMap = if (length == 0) null else try file.createMemoryMap(self.io, .{
            .len = length,
            .protection = .{ .read = true },
            .populate = false,
        });

        self.files[self.mapped_files] = .{ .file = file, .map = map };
        self.mapped_files += 1;
        return self.files[self.mapped_files - 1].bytes();
    }

    fn compareWithSource(self: *CacheTable) !Freshness {
        const source = self.parsed.?.value.source;
        const stat = self.dir.statFile(self.io, source.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return .source_missing,
            else => return err,
        };

        if (stat.size != source.size or stat.mtime.nanoseconds != source.modified_ns) {
            return .stale;
        }
        return .fresh;
    }

    fn fail(self: *CacheTable, err: anyerror, diagnostics: *Diagnostics) TableError {
        diagnostics.push(.{
            .layer = .infra,
            .kind = err,
            .message = self.messageOf(err),
            .location = .{ .path = self.locationOf(err) },
        });
        return translate(err);
    }

    fn locationOf(self: *CacheTable, err: anyerror) []const u8 {
        if (err == error.FileNotFound or self.current_file.len == 0) return self.path;
        return std.fmt.bufPrint(
            &self.location_buffer,
            "{s}/{s}",
            .{ self.path, self.current_file },
        ) catch self.path;
    }

    fn messageOf(self: *CacheTable, err: anyerror) []const u8 {
        return switch (err) {
            error.FileNotFound => "cache not found",
            error.OutOfMemory => "out of memory",
            error.Incomplete => "incomplete cache (meta.json is missing)",
            error.NotACache => "not a tabl cache",
            error.UnsupportedVersion => std.fmt.bufPrint(
                &self.message_buffer,
                "unsupported cache version (expected {d})",
                .{meta.current_version},
            ) catch "unsupported cache version",
            error.InvalidMeta => "invalid meta.json",
            error.InvalidOffsetWidth => "invalid offset width",
            error.PathIsNotAbsolute => "source path is not absolute",
            error.MissingColumnFile => "missing column file",
            error.SizeMismatch => "file size does not match the row count",
            error.MaskSizeMismatch => "empty mask size does not match the row count",
            error.LastEndMismatch => "value positions do not match the text size",
            else => std.fmt.bufPrint(
                &self.message_buffer,
                "cannot read cache ({t})",
                .{err},
            ) catch "cannot read cache",
        };
    }
};

fn translate(err: anyerror) TableError {
    return switch (err) {
        error.FileNotFound => TableError.NotFound,
        error.OutOfMemory => TableError.OutOfMemory,
        error.NotACache, error.UnsupportedVersion => TableError.Unsupported,
        error.Incomplete,
        error.InvalidMeta,
        error.InvalidOffsetWidth,
        error.PathIsNotAbsolute,
        error.MissingColumnFile,
        error.SizeMismatch,
        error.MaskSizeMismatch,
        error.LastEndMismatch,
        => TableError.Malformed,
        else => TableError.Unreadable,
    };
}

const testing = std.testing;
const CacheWriter = @import("writer.zig").CacheWriter;

fn importTable(dir: std.Io.Dir, names: []const []const u8, rows: []const []const Value) !void {
    try dir.writeFile(testing.io, .{ .sub_path = "sales.csv", .data = "city,age\nParis,31\n" });

    var cache: CacheWriter = .new(testing.io, testing.allocator, dir, "sales.tabl", "sales.csv");
    defer cache.close();

    var diagnostics: Diagnostics = .{};
    const table_writer = cache.writer();
    try table_writer.header(.{ .names = names }, &diagnostics);
    for (rows) |values| {
        try table_writer.row(.{ .values = values }, &diagnostics);
    }
    try table_writer.finish(&diagnostics);
}

test "reads back every value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try importTable(tmp.dir, &.{ "city", "age" }, &.{
        &.{ .{ .text = "Paris" }, .{ .text = "31" } },
        &.{ .empty, .{ .text = "45" } },
        &.{ .{ .text = "Lyon" }, .{ .text = "" } },
    });

    var cache: CacheTable = .new(testing.io, testing.allocator, tmp.dir, "sales.tabl");
    defer cache.close();
    const table = cache.table();
    var diagnostics: Diagnostics = .{};

    const names = (try table.header(&diagnostics)).names;
    try testing.expectEqual(2, names.len);
    try testing.expectEqualStrings("age", names[1]);
    try testing.expectEqual(3, try table.rowCount(&diagnostics));

    try testing.expectEqualDeep(Value{ .text = "Paris" }, table.value(0, 0));
    try testing.expectEqualDeep(Value{ .text = "31" }, table.value(0, 1));
    try testing.expectEqualDeep(Value.empty, table.value(1, 0));
    try testing.expectEqualDeep(Value{ .text = "Lyon" }, table.value(2, 0));
    try testing.expectEqualDeep(Value{ .text = "" }, table.value(2, 1));
    try testing.expectEqual(.fresh, try table.freshness(&diagnostics));
}

test "reads a table without rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try importTable(tmp.dir, &.{ "city", "age" }, &.{});

    var cache: CacheTable = .new(testing.io, testing.allocator, tmp.dir, "sales.tabl");
    defer cache.close();
    var diagnostics: Diagnostics = .{};

    try testing.expectEqual(0, try cache.table().rowCount(&diagnostics));
    try testing.expectEqual(2, (try cache.table().header(&diagnostics)).names.len);
}

fn removeCache(dir: std.Io.Dir) !void {
    try dir.deleteTree(testing.io, "sales.tabl");
}

fn removeMeta(dir: std.Io.Dir) !void {
    try dir.deleteFile(testing.io, "sales.tabl/meta.json");
}

fn replaceFormat(dir: std.Io.Dir) !void {
    try dir.writeFile(testing.io, .{
        .sub_path = "sales.tabl/meta.json",
        .data = "{ \"format\": \"other\", \"version\": 1 }",
    });
}

fn replaceVersion(dir: std.Io.Dir) !void {
    try dir.writeFile(testing.io, .{
        .sub_path = "sales.tabl/meta.json",
        .data = "{ \"format\": \"tabl-cache\", \"version\": 2 }",
    });
}

fn removeColumnFile(dir: std.Io.Dir) !void {
    try dir.deleteFile(testing.io, "sales.tabl/1.bytes");
}

fn truncateEnds(dir: std.Io.Dir) !void {
    try dir.writeFile(testing.io, .{ .sub_path = "sales.tabl/0.ends", .data = &.{ 5, 0, 0, 0 } });
}

fn removeEmptyMask(dir: std.Io.Dir) !void {
    try dir.deleteFile(testing.io, "sales.tabl/0.empty");
}

fn extendEmptyMask(dir: std.Io.Dir) !void {
    try dir.writeFile(testing.io, .{ .sub_path = "sales.tabl/1.empty", .data = &.{ 0, 0 } });
}

fn extendBytes(dir: std.Io.Dir) !void {
    try dir.writeFile(testing.io, .{ .sub_path = "sales.tabl/0.bytes", .data = "ParisLyonNice" });
}

test "refuses a damaged cache" {
    const Case = struct {
        name: []const u8,
        damage: *const fn (std.Io.Dir) anyerror!void,
        expected: TableError,
        message: []const u8,
        path: []const u8,
    };

    const cases = [_]Case{
        .{
            .name = "error_no_cache",
            .damage = removeCache,
            .expected = TableError.NotFound,
            .message = "cache not found",
            .path = "sales.tabl",
        },
        .{
            .name = "error_no_meta",
            .damage = removeMeta,
            .expected = TableError.Malformed,
            .message = "incomplete cache (meta.json is missing)",
            .path = "sales.tabl/meta.json",
        },
        .{
            .name = "error_not_a_cache",
            .damage = replaceFormat,
            .expected = TableError.Unsupported,
            .message = "not a tabl cache",
            .path = "sales.tabl/meta.json",
        },
        .{
            .name = "error_newer_version",
            .damage = replaceVersion,
            .expected = TableError.Unsupported,
            .message = "unsupported cache version (expected 1)",
            .path = "sales.tabl/meta.json",
        },
        .{
            .name = "error_missing_column_file",
            .damage = removeColumnFile,
            .expected = TableError.Malformed,
            .message = "missing column file",
            .path = "sales.tabl/1.bytes",
        },
        .{
            .name = "error_missing_empty_mask",
            .damage = removeEmptyMask,
            .expected = TableError.Malformed,
            .message = "missing column file",
            .path = "sales.tabl/0.empty",
        },
        .{
            .name = "error_empty_mask_too_long",
            .damage = extendEmptyMask,
            .expected = TableError.Malformed,
            .message = "empty mask size does not match the row count",
            .path = "sales.tabl/1.empty",
        },
        .{
            .name = "error_truncated_ends",
            .damage = truncateEnds,
            .expected = TableError.Malformed,
            .message = "file size does not match the row count",
            .path = "sales.tabl/0.ends",
        },
        .{
            .name = "error_bytes_longer_than_ends",
            .damage = extendBytes,
            .expected = TableError.Malformed,
            .message = "value positions do not match the text size",
            .path = "sales.tabl/0.ends",
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try importTable(tmp.dir, &.{ "city", "age" }, &.{
            &.{ .{ .text = "Paris" }, .{ .text = "31" } },
            &.{ .{ .text = "Lyon" }, .{ .text = "45" } },
        });
        try case.damage(tmp.dir);

        var cache: CacheTable = .new(testing.io, testing.allocator, tmp.dir, "sales.tabl");
        defer cache.close();
        var diagnostics: Diagnostics = .{};

        try testing.expectError(case.expected, cache.table().header(&diagnostics));
        try testing.expectError(case.expected, cache.table().rowCount(&diagnostics));
        try testing.expectEqual(2, diagnostics.size);
        try testing.expectEqualStrings(case.message, diagnostics.last().?.message);
        try testing.expectEqualStrings(case.path, diagnostics.last().?.location.?.path);
    }
}

test "freshness" {
    const Case = struct {
        name: []const u8,
        change: ?[]const u8,
        expected: Freshness,
    };

    const cases = [_]Case{
        .{ .name = "ok_fresh", .change = null, .expected = .fresh },
        .{ .name = "ok_stale", .change = "city,age\nParis,31\nLyon,45\n", .expected = .stale },
        .{ .name = "ok_source_missing", .change = "", .expected = .source_missing },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try importTable(tmp.dir, &.{"city"}, &.{&.{.{ .text = "Paris" }}});

        if (case.change) |data| {
            if (data.len == 0) {
                try tmp.dir.deleteFile(testing.io, "sales.csv");
            } else {
                try tmp.dir.writeFile(testing.io, .{ .sub_path = "sales.csv", .data = data });
            }
        }

        var cache: CacheTable = .new(testing.io, testing.allocator, tmp.dir, "sales.tabl");
        defer cache.close();
        var diagnostics: Diagnostics = .{};

        try testing.expectEqual(case.expected, try cache.table().freshness(&diagnostics));
    }
}
