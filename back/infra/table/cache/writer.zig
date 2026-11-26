const std = @import("std");
const Diagnostics = @import("../../../core/diagnostic.zig").Diagnostics;
const Header = @import("../../../core/table/header.zig").Header;
const Type = @import("../../../core/table/type/type.zig").Type;
const ColumnType = @import("../../../core/table/type/type.zig").ColumnType;
const Row = @import("../../../core/table/row.zig").Row;
const Value = @import("../../../core/table/value.zig").Value;
const Writer = @import("../../../core/table/writer.zig").Writer;
const TableError = @import("../../../core/table/errors.zig").TableError;
const meta = @import("meta.zig");
const EmptyFile = @import("empty_file.zig").EmptyFile;
const TextFiles = @import("text_files.zig").TextFiles;
const ValuesFile = @import("values_file.zig").ValuesFile;
const widthOf = @import("values_file.zig").widthOf;

const buffer_size = 64 * 1024;

const ColumnFiles = struct {
    empty: EmptyFile,
    data: Data,

    const Data = union(enum) {
        text: TextFiles,
        values: ValuesFile,
    };

    fn close(self: ColumnFiles, io: std.Io) void {
        self.empty.close(io);
        switch (self.data) {
            .text => |text| text.close(io),
            .values => |values| values.close(io),
        }
    }
};

pub const CacheWriter = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    path: []const u8,
    source_path: []const u8,
    narrow_limit: u64 = std.math.maxInt(u32),
    arena: std.heap.ArenaAllocator,
    cache_dir: ?std.Io.Dir = null,
    columns: []ColumnFiles = &.{},
    opened_columns: usize = 0,
    names: []const []const u8 = &.{},
    types: []Type = &.{},
    source: meta.Source = .{ .path = "", .size = 0, .modified_ns = 0 },
    rows: u32 = 0,
    finished: bool = false,
    message_buffer: [128]u8 = undefined,

    pub fn new(
        io: std.Io,
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        path: []const u8,
        source_path: []const u8,
    ) CacheWriter {
        return .{
            .io = io,
            .allocator = allocator,
            .dir = dir,
            .path = path,
            .source_path = source_path,
            .arena = .init(allocator),
        };
    }

    pub fn close(self: *CacheWriter) void {
        for (self.columns[0..self.opened_columns]) |column| {
            column.close(self.io);
        }
        if (self.cache_dir) |cache_dir| {
            cache_dir.close(self.io);
        }
        self.arena.deinit();
        self.* = .new(
            self.io,
            self.allocator,
            self.dir,
            self.path,
            self.source_path,
        );
    }

    pub fn writer(self: *CacheWriter) Writer {
        return .{
            .ptr = self,
            .vtable = &.{ .header = header, .row = row, .finish = finish },
        };
    }

    fn header(
        ptr: *anyopaque,
        value: Header,
        types: []const ColumnType,
        diagnostics: *Diagnostics,
    ) TableError!void {
        const self: *CacheWriter = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.cache_dir == null);
        std.debug.assert(types.len == value.names.len);
        self.prepare(value.names, types) catch |err| return self.fail(err, diagnostics);
    }

    fn row(
        ptr: *anyopaque,
        value: Row,
        diagnostics: *Diagnostics,
    ) TableError!void {
        const self: *CacheWriter = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.cache_dir != null and !self.finished);
        std.debug.assert(value.values.len == self.columns.len);
        self.appendRow(value.values) catch |err| return self.fail(err, diagnostics);
    }

    fn finish(ptr: *anyopaque, diagnostics: *Diagnostics) TableError!void {
        const self: *CacheWriter = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.cache_dir != null and !self.finished);
        self.writeMeta() catch |err| return self.fail(err, diagnostics);
        self.finished = true;
    }

    fn prepare(
        self: *CacheWriter,
        names: []const []const u8,
        types: []const ColumnType,
    ) !void {
        const arena = self.arena.allocator();

        const stat = try self.dir.statFile(self.io, self.source_path, .{});
        self.source = .{
            .path = try self.dir.realPathFileAlloc(self.io, self.source_path, arena),
            .size = stat.size,
            .modified_ns = std.math.cast(i64, stat.mtime.nanoseconds) orelse return error.Overflow,
        };
        self.names = try copyTexts(arena, names);
        self.types = try arena.alloc(Type, types.len);
        for (types, self.types) |column_type, *copied| {
            copied.* = std.meta.activeTag(column_type);
        }

        const cache_dir = try self.dir.createDirPathOpen(self.io, self.path, .{});
        self.cache_dir = cache_dir;
        cache_dir.deleteFile(self.io, meta.file_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        self.columns = try arena.alloc(ColumnFiles, names.len);
        for (self.columns, self.types, 0..) |*column, column_type, index| {
            column.* = try self.createColumnFiles(cache_dir, index, column_type);
            self.opened_columns += 1;
        }
    }

    fn createColumnFiles(
        self: *CacheWriter,
        cache_dir: std.Io.Dir,
        index: usize,
        column_type: Type,
    ) !ColumnFiles {
        const empty: EmptyFile = try .create(self.io, cache_dir, index, try self.newBuffer());
        errdefer empty.close(self.io);

        const data: ColumnFiles.Data = if (widthOf(column_type)) |width|
            .{ .values = try .create(self.io, cache_dir, index, width, try self.newBuffer()) }
        else
            .{ .text = try .create(self.io, cache_dir, index, try self.newBuffer(), try self.newBuffer()) };

        return .{ .empty = empty, .data = data };
    }

    fn newBuffer(self: *CacheWriter) ![]u8 {
        return self.arena.allocator().alloc(u8, buffer_size);
    }

    fn appendRow(self: *CacheWriter, values: []const Value) !void {
        if (self.rows == std.math.maxInt(u32)) return error.TooManyRows;

        for (self.columns, values, 0..) |*column, value, index| {
            try column.empty.appendBit(self.rows, value == .empty);
            switch (column.data) {
                .text => |*text| try text.append(self.io, self.cache_dir.?, index, value, self.narrow_limit),
                .values => |*values_file| try values_file.append(value),
            }
        }

        self.rows += 1;
    }

    fn writeMeta(self: *CacheWriter) !void {
        const arena = self.arena.allocator();

        const columns = try arena.alloc(meta.Column, self.columns.len);
        for (self.columns, self.names, self.types, columns) |*files, name, column_type, *column| {
            try files.empty.finish(self.rows);
            column.* = .{ .name = name, .type = column_type };
            switch (files.data) {
                .text => |*text| {
                    try text.finish();
                    column.offset_width = text.offset_width;
                },
                .values => |*values| try values.finish(),
            }
        }

        const file = try self.cache_dir.?.createFile(
            self.io,
            meta.file_name,
            .{},
        );
        defer file.close(self.io);

        var buffer: [4096]u8 = undefined;
        var file_writer: std.Io.File.Writer = .init(file, self.io, &buffer);
        meta.write(.{
            .format = meta.format_name,
            .version = meta.current_version,
            .rows = self.rows,
            .source = self.source,
            .columns = columns,
        }, &file_writer.interface) catch return file_writer.err orelse error.WriteFailed;
        try file_writer.flush();
    }

    fn fail(
        self: *CacheWriter,
        err: anyerror,
        diagnostics: *Diagnostics,
    ) TableError {
        diagnostics.push(.{
            .layer = .infra,
            .kind = err,
            .message = self.messageOf(err),
            .location = .{
                .path = if (err == error.FileNotFound) self.source_path else self.path,
            },
        });
        return translate(err);
    }

    fn messageOf(self: *CacheWriter, err: anyerror) []const u8 {
        return switch (err) {
            error.FileNotFound => "source file not found",
            error.OutOfMemory => "out of memory",
            error.NoSpaceLeft => "no space left on device",
            error.AccessDenied, error.PermissionDenied => "permission denied",
            error.TooManyRows => "too many rows (at most 4294967295)",
            else => std.fmt.bufPrint(
                &self.message_buffer,
                "cannot write cache ({t})",
                .{err},
            ) catch "cannot write cache",
        };
    }
};

fn translate(err: anyerror) TableError {
    return switch (err) {
        error.FileNotFound => TableError.NotFound,
        error.OutOfMemory => TableError.OutOfMemory,
        else => TableError.Unwritable,
    };
}

fn copyTexts(
    allocator: std.mem.Allocator,
    texts: []const []const u8,
) ![]const []const u8 {
    const copies = try allocator.alloc([]const u8, texts.len);
    for (texts, copies) |text, *copied| {
        copied.* = try allocator.dupe(u8, text);
    }
    return copies;
}

const testing = std.testing;

fn writeTable(
    cache: *CacheWriter,
    names: []const []const u8,
    types: []const ColumnType,
    rows: []const []const Value,
) !void {
    var diagnostics: Diagnostics = .{};
    const table_writer = cache.writer();
    try table_writer.header(.{ .names = names }, types, &diagnostics);
    for (rows) |values| {
        try table_writer.row(.{ .values = values }, &diagnostics);
    }
    try table_writer.finish(&diagnostics);
}

fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const bytes = try dir.readFileAlloc(
        testing.io,
        path,
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, expected, bytes);
}

test "writes the files described in FORMAT.md" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sales.csv",
        .data = "city,age\nParis,31\nLyon,45\n,\n",
    });

    var cache: CacheWriter = .new(
        testing.io,
        testing.allocator,
        tmp.dir,
        "sales.tabl",
        "sales.csv",
    );
    defer cache.close();
    try writeTable(
        &cache,
        &.{ "city", "age" },
        &.{ .text, .integer },
        &.{
            &.{ .{ .text = "Paris" }, .{ .integer = 31 } },
            &.{ .{ .text = "Lyon" }, .{ .integer = 45 } },
            &.{ .empty, .empty },
        },
    );

    try expectFile(tmp.dir, "sales.tabl/0.bytes", "ParisLyon");
    try expectFile(tmp.dir, "sales.tabl/0.ends", &.{ 5, 0, 0, 0, 9, 0, 0, 0, 9, 0, 0, 0 });
    try expectFile(tmp.dir, "sales.tabl/0.empty", &.{0x04});
    try expectFile(tmp.dir, "sales.tabl/1.values", &.{
        0x1F, 0, 0, 0, 0, 0, 0, 0,
        0x2D, 0, 0, 0, 0, 0, 0, 0,
        0,    0, 0, 0, 0, 0, 0, 0,
    });
    try expectFile(tmp.dir, "sales.tabl/1.empty", &.{0x04});
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(testing.io, "sales.tabl/1.ends", .{}),
    );

    const bytes = try tmp.dir.readFileAlloc(
        testing.io,
        "sales.tabl/meta.json",
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(bytes);
    const parsed = try meta.parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(3, parsed.value.rows);
    try testing.expectEqual(28, parsed.value.source.size);
    try testing.expect(
        std.mem.endsWith(u8, parsed.value.source.path, "/sales.csv"),
    );
    try testing.expectEqual(.text, parsed.value.columns[0].type);
    try testing.expectEqual(32, parsed.value.columns[0].offset_width);
    try testing.expectEqualStrings("age", parsed.value.columns[1].name);
    try testing.expectEqual(.integer, parsed.value.columns[1].type);
    try testing.expectEqual(null, parsed.value.columns[1].offset_width);
}

test "writes every fixed-width type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sales.csv", .data = "" });

    var cache: CacheWriter = .new(
        testing.io,
        testing.allocator,
        tmp.dir,
        "sales.tabl",
        "sales.csv",
    );
    defer cache.close();
    try writeTable(
        &cache,
        &.{ "price", "day", "paid" },
        &.{ .decimal, .{ .date = .year_month_day_dash }, .boolean },
        &.{
            &.{ .{ .decimal = 1.5 }, .{ .date = -1 }, .{ .boolean = true } },
            &.{ .empty, .empty, .empty },
        },
    );

    try expectFile(tmp.dir, "sales.tabl/0.values", &.{
        0, 0, 0, 0, 0, 0, 0xF8, 0x3F,
        0, 0, 0, 0, 0, 0, 0,    0,
    });
    try expectFile(tmp.dir, "sales.tabl/1.values", &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0 });
    try expectFile(tmp.dir, "sales.tabl/2.values", &.{ 1, 0 });
    try expectFile(tmp.dir, "sales.tabl/0.empty", &.{0x02});
    try expectFile(tmp.dir, "sales.tabl/1.empty", &.{0x02});
    try expectFile(tmp.dir, "sales.tabl/2.empty", &.{0x02});
}

test "writes no meta.json until finish" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(
        testing.io,
        .{ .sub_path = "sales.csv", .data = "city\nParis\n" },
    );
    try tmp.dir.createDirPath(testing.io, "sales.tabl");
    try tmp.dir.writeFile(
        testing.io,
        .{ .sub_path = "sales.tabl/meta.json", .data = "{}" },
    );

    var cache: CacheWriter = .new(
        testing.io,
        testing.allocator,
        tmp.dir,
        "sales.tabl",
        "sales.csv",
    );
    defer cache.close();
    var diagnostics: Diagnostics = .{};
    const table_writer = cache.writer();
    try table_writer.header(.{ .names = &.{"city"} }, &.{.text}, &diagnostics);
    try table_writer.row(.{ .values = &.{.{ .text = "Paris" }} }, &diagnostics);

    try testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(testing.io, "sales.tabl/meta.json", .{}),
    );
}

test "widens a column past the narrow limit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sales.csv", .data = "" });

    var cache: CacheWriter = .new(
        testing.io,
        testing.allocator,
        tmp.dir,
        "sales.tabl",
        "sales.csv",
    );
    defer cache.close();
    cache.narrow_limit = 6;
    try writeTable(
        &cache,
        &.{ "city", "age" },
        &.{ .text, .text },
        &.{
            &.{ .{ .text = "Paris" }, .{ .text = "31" } },
            &.{ .{ .text = "Lyon" }, .{ .text = "45" } },
        },
    );

    try expectFile(
        tmp.dir,
        "sales.tabl/0.ends",
        &.{ 5, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0 },
    );
    try expectFile(tmp.dir, "sales.tabl/1.ends", &.{ 2, 0, 0, 0, 4, 0, 0, 0 });
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(testing.io, "sales.tabl/0.ends.wide", .{}),
    );

    const bytes = try tmp.dir.readFileAlloc(
        testing.io,
        "sales.tabl/meta.json",
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(bytes);
    const parsed = try meta.parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(64, parsed.value.columns[0].offset_width);
    try testing.expectEqual(32, parsed.value.columns[1].offset_width);
}

test "writes a mask spanning several bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sales.csv", .data = "" });

    var cache: CacheWriter = .new(
        testing.io,
        testing.allocator,
        tmp.dir,
        "sales.tabl",
        "sales.csv",
    );
    defer cache.close();

    const paris: []const Value = &.{.{ .text = "Paris" }};
    const empty: []const Value = &.{.empty};
    try writeTable(
        &cache,
        &.{"city"},
        &.{.text},
        &.{ empty, paris, paris, paris, paris, paris, paris, paris, empty, empty },
    );

    try expectFile(tmp.dir, "sales.tabl/0.empty", &.{ 0x01, 0x03 });
}

test "fails when the source is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var cache: CacheWriter = .new(
        testing.io,
        testing.allocator,
        tmp.dir,
        "sales.tabl",
        "missing.csv",
    );
    defer cache.close();
    var diagnostics: Diagnostics = .{};

    try testing.expectError(
        error.NotFound,
        cache.writer().header(.{ .names = &.{"city"} }, &.{.text}, &diagnostics),
    );
    try testing.expectEqual(1, diagnostics.size);
    try testing.expectEqualStrings(
        "source file not found",
        diagnostics.last().?.message,
    );
    try testing.expectEqualStrings(
        "missing.csv",
        diagnostics.last().?.location.?.path,
    );
}
