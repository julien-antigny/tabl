const std = @import("std");
const Diagnostics = @import("../../../core/diagnostic.zig").Diagnostics;
const Header = @import("../../../core/table/header.zig").Header;
const Row = @import("../../../core/table/row.zig").Row;
const Value = @import("../../../core/table/value.zig").Value;
const Writer = @import("../../../core/table/writer.zig").Writer;
const TableError = @import("../../../core/table/errors.zig").TableError;
const CacheError = @import("errors.zig").CacheError;
const meta = @import("meta.zig");

const buffer_size = 64 * 1024;

const ColumnFiles = struct {
    ends_file: std.Io.File,
    ends_writer: std.Io.File.Writer,
    bytes_file: std.Io.File,
    bytes_writer: std.Io.File.Writer,
    empty_file: std.Io.File,
    empty_writer: std.Io.File.Writer,
    offset_width: u32 = 32,
    end: u64 = 0,
    pending_mask: u8 = 0,
};

const FileName = [32]u8;

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
            column.ends_file.close(self.io);
            column.bytes_file.close(self.io);
            column.empty_file.close(self.io);
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
        diagnostics: *Diagnostics,
    ) TableError!void {
        const self: *CacheWriter = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.cache_dir == null);
        self.prepare(value.names) catch |err| return self.fail(err, diagnostics);
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

    fn prepare(self: *CacheWriter, names: []const []const u8) !void {
        const arena = self.arena.allocator();

        const stat = try self.dir.statFile(self.io, self.source_path, .{});
        self.source = .{
            .path = try self.dir.realPathFileAlloc(self.io, self.source_path, arena),
            .size = stat.size,
            .modified_ns = std.math.cast(i64, stat.mtime.nanoseconds) orelse return error.Overflow,
        };
        self.names = try copyTexts(arena, names);

        const cache_dir = try self.dir.createDirPathOpen(self.io, self.path, .{});
        self.cache_dir = cache_dir;
        cache_dir.deleteFile(self.io, meta.file_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        self.columns = try arena.alloc(ColumnFiles, names.len);
        for (self.columns, 0..) |*column, index| {
            column.* = try self.createColumnFiles(cache_dir, index);
            self.opened_columns += 1;
        }
    }

    fn createColumnFiles(
        self: *CacheWriter,
        cache_dir: std.Io.Dir,
        index: usize,
    ) !ColumnFiles {
        const arena = self.arena.allocator();
        var name: FileName = undefined;

        const ends_file = try cache_dir.createFile(
            self.io,
            fileName(&name, index, "ends"),
            .{ .read = true },
        );
        errdefer ends_file.close(self.io);
        const bytes_file = try cache_dir.createFile(
            self.io,
            fileName(&name, index, "bytes"),
            .{},
        );
        errdefer bytes_file.close(self.io);
        const empty_file = try cache_dir.createFile(
            self.io,
            fileName(&name, index, "empty"),
            .{},
        );
        errdefer empty_file.close(self.io);

        return .{
            .ends_file = ends_file,
            .ends_writer = .init(
                ends_file,
                self.io,
                try arena.alloc(u8, buffer_size),
            ),
            .bytes_file = bytes_file,
            .bytes_writer = .init(
                bytes_file,
                self.io,
                try arena.alloc(u8, buffer_size),
            ),
            .empty_file = empty_file,
            .empty_writer = .init(
                empty_file,
                self.io,
                try arena.alloc(u8, buffer_size),
            ),
        };
    }

    fn appendRow(self: *CacheWriter, values: []const Value) !void {
        if (self.rows == std.math.maxInt(u32)) return error.TooManyRows;

        for (self.columns, values, 0..) |*column, value, index| {
            const text = switch (value) {
                .empty => "",
                .text => |text| text,
            };
            column.bytes_writer.interface.writeAll(text) catch return writeErrorOf(
                &column.bytes_writer,
            );
            column.end += text.len;

            if (column.offset_width == 32 and column.end > self.narrow_limit) {
                try self.widenEnds(column, index);
            }
            try writeEnd(column);
            try appendEmptyBit(column, self.rows, value == .empty);
        }

        self.rows += 1;
    }

    fn widenEnds(self: *CacheWriter, column: *ColumnFiles, index: usize) !void {
        const cache_dir = self.cache_dir.?;
        var narrow_name: FileName = undefined;
        var wide_name: FileName = undefined;

        try column.ends_writer.flush();

        const wide_file = try cache_dir.createFile(
            self.io,
            fileName(&wide_name, index, "ends.wide"),
            .{},
        );
        errdefer wide_file.close(self.io);
        var wide_writer: std.Io.File.Writer = .init(
            wide_file,
            self.io,
            column.ends_writer.interface.buffer,
        );

        var chunk: [4096]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const read = try column.ends_file.readPositionalAll(
                self.io,
                &chunk,
                offset,
            );
            if (read == 0) break;

            var position: usize = 0;
            while (position < read) : (position += 4) {
                const end = std.mem.readInt(
                    u32,
                    chunk[position..][0..4],
                    .little,
                );
                wide_writer.interface.writeInt(
                    u64,
                    end,
                    .little,
                ) catch return writeErrorOf(
                    &wide_writer,
                );
            }
            offset += read;
        }

        try cache_dir.rename(
            fileName(&wide_name, index, "ends.wide"),
            cache_dir,
            fileName(&narrow_name, index, "ends"),
            self.io,
        );
        column.ends_file.close(self.io);
        column.ends_file = wide_file;
        column.ends_writer = wide_writer;
        column.offset_width = 64;
    }

    fn writeMeta(self: *CacheWriter) !void {
        const arena = self.arena.allocator();

        const columns = try arena.alloc(meta.Column, self.columns.len);
        for (self.columns, self.names, columns) |*files, name, *column| {
            try writePendingMask(files, self.rows);
            try files.ends_writer.flush();
            try files.bytes_writer.flush();
            try files.empty_writer.flush();
            column.* = .{ .name = name, .offset_width = files.offset_width };
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
        }, &file_writer.interface) catch return writeErrorOf(&file_writer);
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

fn writeErrorOf(file_writer: *const std.Io.File.Writer) anyerror {
    return file_writer.err orelse error.WriteFailed;
}

fn writeEnd(column: *ColumnFiles) !void {
    const result = switch (column.offset_width) {
        32 => column.ends_writer.interface.writeInt(
            u32,
            @intCast(column.end),
            .little,
        ),
        64 => column.ends_writer.interface.writeInt(u64, column.end, .little),
        else => unreachable,
    };
    result catch return writeErrorOf(&column.ends_writer);
}

fn appendEmptyBit(column: *ColumnFiles, row: u32, is_empty: bool) !void {
    const bit: u3 = @intCast(row % 8);
    if (is_empty) {
        column.pending_mask |= @as(u8, 1) << bit;
    }
    if (bit == 7) {
        column.empty_writer.interface.writeByte(column.pending_mask) catch return writeErrorOf(
            &column.empty_writer,
        );
        column.pending_mask = 0;
    }
}

fn writePendingMask(column: *ColumnFiles, rows: u32) !void {
    if (rows % 8 == 0) return;
    column.empty_writer.interface.writeByte(column.pending_mask) catch return writeErrorOf(
        &column.empty_writer,
    );
    column.pending_mask = 0;
}

fn fileName(buffer: *FileName, index: usize, extension: []const u8) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{d}.{s}",
        .{ index, extension },
    ) catch unreachable;
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
    rows: []const []const Value,
) !void {
    var diagnostics: Diagnostics = .{};
    const table_writer = cache.writer();
    try table_writer.header(.{ .names = names }, &diagnostics);
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
        .data = "city,age\nParis,31\nLyon,45\n,\"\"\n",
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
        &.{
            &.{ .{ .text = "Paris" }, .{ .text = "31" } },
            &.{ .{ .text = "Lyon" }, .{ .text = "45" } },
            &.{ .empty, .{ .text = "" } },
        },
    );

    try expectFile(tmp.dir, "sales.tabl/0.bytes", "ParisLyon");
    try expectFile(tmp.dir, "sales.tabl/0.ends", &.{ 5, 0, 0, 0, 9, 0, 0, 0, 9, 0, 0, 0 });
    try expectFile(tmp.dir, "sales.tabl/0.empty", &.{0x04});
    try expectFile(tmp.dir, "sales.tabl/1.bytes", "3145");
    try expectFile(tmp.dir, "sales.tabl/1.ends", &.{ 2, 0, 0, 0, 4, 0, 0, 0, 4, 0, 0, 0 });
    try expectFile(tmp.dir, "sales.tabl/1.empty", &.{0x00});

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
    try testing.expectEqual(30, parsed.value.source.size);
    try testing.expect(
        std.mem.endsWith(u8, parsed.value.source.path, "/sales.csv"),
    );
    try testing.expectEqualStrings("age", parsed.value.columns[1].name);
    try testing.expectEqual(32, parsed.value.columns[1].offset_width);
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
    try table_writer.header(.{ .names = &.{"city"} }, &diagnostics);
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
        cache.writer().header(.{ .names = &.{"city"} }, &diagnostics),
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
