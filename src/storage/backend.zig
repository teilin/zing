const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const testing = std.testing;

/// Pluggable storage backend interface for Zing.
///
/// Two backends are provided:
///   - FileBackend: persists blobs as files on disk
///   - MemBackend: in-memory storage, lost on shutdown

pub const StorageBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Create or replace a blob. Returns the content length written.
        put: *const fn(ctx: *anyopaque, container: []const u8, blob: []const u8, data: []const u8, content_type: []const u8) anyerror!u64,

        /// Read a blob's content. Returns empty slice if not found.
        get: *const fn(ctx: *anyopaque, container: []const u8, blob: []const u8, range_start: ?u64, range_end: ?u64) anyerror!GetResult,

        /// Get blob metadata (content-type, content-length, etc).
        stat: *const fn(ctx: *anyopaque, container: []const u8, blob: []const u8) anyerror!StatResult,

        /// Delete a blob.
        delete: *const fn(ctx: *anyopaque, container: []const u8, blob: []const u8) anyerror!void,

        /// List containers. Returns an iterator owned by the caller.
        listContainers: *const fn(ctx: *anyopaque) anyerror!ContainerIterator,

        /// List blobs in a container. Returns an iterator owned by the caller.
        listBlobs: *const fn(ctx: *anyopaque, container: []const u8, prefix: []const u8) anyerror!BlobIterator,

        /// Create a container.
        createContainer: *const fn(ctx: *anyopaque, container: []const u8) anyerror!void,

        /// Delete a container and all its blobs.
        deleteContainer: *const fn(ctx: *anyopaque, container: []const u8) anyerror!void,

        /// Check if a container exists.
        containerExists: *const fn(ctx: *anyopaque, container: []const u8) anyerror!bool,

        /// Get container properties (lease state, etc).
        containerProperties: *const fn(ctx: *anyopaque, container: []const u8) anyerror!ContainerProperties,

        /// Close/free the backend.
        close: *const fn(ctx: *anyopaque) void,
    };

    pub const GetResult = struct {
        data: []const u8,
        content_type: []const u8,
        content_length: u64,
        etag: []const u8,
        last_modified: i64, // Unix timestamp in seconds
    };

    pub const StatResult = struct {
        content_type: []const u8,
        content_length: u64,
        etag: []const u8,
        last_modified: i64,
        creation_time: i64,
        metadata: std.StringHashMap([]const u8),
    };

    pub const ContainerProperties = struct {
        last_modified: i64,
        lease_status: []const u8,
        lease_state: []const u8,
        public_access: []const u8,
    };

    pub const ContainerItem = struct {
        name: []const u8,
        last_modified: i64,
        etag: []const u8,
        lease_status: []const u8,
        lease_state: []const u8,
    };

    pub const BlobItem = struct {
        name: []const u8,
        content_length: u64,
        content_type: []const u8,
        etag: []const u8,
        last_modified: i64,
        is_committed: bool,
        metadata: std.StringHashMap([]const u8),
    };

    pub const ContainerIterator = struct {
        items: []const ContainerItem,
        index: usize,

        pub fn next(self: *ContainerIterator) ?*const ContainerItem {
            if (self.index >= self.items.len) return null;
            const item = &self.items[self.index];
            self.index += 1;
            return item;
        }
    };

    pub const BlobIterator = struct {
        items: []const BlobItem,
        index: usize,

        pub fn next(self: *BlobIterator) ?*const BlobItem {
            if (self.index >= self.items.len) return null;
            const item = &self.items[self.index];
            self.index += 1;
            return item;
        }
    };

    /// Thin wrapper that delegates to the vtable.
    pub fn put(self: StorageBackend, container: []const u8, blob: []const u8, data: []const u8, content_type: []const u8) !u64 {
        return self.vtable.put(self.ptr, container, blob, data, content_type);
    }

    pub fn get(self: StorageBackend, container: []const u8, blob: []const u8, range_start: ?u64, range_end: ?u64) !GetResult {
        return self.vtable.get(self.ptr, container, blob, range_start, range_end);
    }

    pub fn stat(self: StorageBackend, container: []const u8, blob: []const u8) !StatResult {
        return self.vtable.stat(self.ptr, container, blob);
    }

    pub fn delete(self: StorageBackend, container: []const u8, blob: []const u8) !void {
        return self.vtable.delete(self.ptr, container, blob);
    }

    pub fn listContainers(self: StorageBackend) !ContainerIterator {
        return self.vtable.listContainers(self.ptr);
    }

    pub fn listBlobs(self: StorageBackend, container: []const u8, prefix: []const u8) !BlobIterator {
        return self.vtable.listBlobs(self.ptr, container, prefix);
    }

    pub fn createContainer(self: StorageBackend, container: []const u8) !void {
        return self.vtable.createContainer(self.ptr, container);
    }

    pub fn deleteContainer(self: StorageBackend, container: []const u8) !void {
        return self.vtable.deleteContainer(self.ptr, container);
    }

    pub fn containerExists(self: StorageBackend, container: []const u8) !bool {
        return self.vtable.containerExists(self.ptr, container);
    }

    pub fn containerProperties(self: StorageBackend, container: []const u8) !ContainerProperties {
        return self.vtable.containerProperties(self.ptr, container);
    }

    pub fn close(self: StorageBackend) void {
        return self.vtable.close(self.ptr);
    }

    /// Factory: create a file-backed storage engine.
    pub fn initFile(allocator: std.mem.Allocator, workspace: []const u8) !StorageBackend {
        return try FileBackend.create(allocator, workspace);
    }

    /// Factory: create an in-memory storage engine.
    pub fn initInMemory(allocator: std.mem.Allocator) !StorageBackend {
        return try MemBackend.create(allocator);
    }

    /// Deinit the backend.
    pub fn deinit(self: StorageBackend) void {
        self.close();
    }
};

// ============================================================================================
// FileBackend — persists blobs as files under a workspace directory
// ============================================================================================

pub const FileBackend = struct {
    workspace: []const u8,
    allocator: mem.Allocator,
    /// In-memory extent store: maps "container/blob" → extent data
    /// Used for uncommitted blocks before they are committed via PutBlockList.
    extent_store: std.StringHashMap(ExtentData),

    pub const ExtentData = struct {
        data: []u8,
        content_type: []const u8,
        created_at: i64,
    };

    pub fn init(allocator: mem.Allocator, workspace: []const u8) !FileBackend {
        // Ensure workspace directory exists
        try fs.cwd().makePath(workspace);

        return .{
            .workspace = workspace,
            .allocator = allocator,
            .extent_store = std.StringHashMap(ExtentData).init(allocator),
        };
    }

    pub fn create(allocator: mem.Allocator, workspace: []const u8) !StorageBackend {
        const backend = try allocator.create(FileBackend);
        backend.* = try init(allocator, workspace);
        return StorageBackend{
            .ptr = @ptrCast(backend),
            .vtable = &.{
                .put = put,
                .get = get,
                .stat = stat,
                .delete = delete,
                .listContainers = listContainers,
                .listBlobs = listBlobs,
                .createContainer = createContainer,
                .deleteContainer = deleteContainer,
                .containerExists = containerExists,
                .containerProperties = containerProperties,
                .close = close,
            },
        };
    }

    fn pathFor(self: *FileBackend, container: []const u8, blob: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.workspace, container, blob });
    }

    fn now() i64 {
        return @intCast(std.time.timestamp());
    }

    fn put(ctx: *anyopaque, container: []const u8, blob: []const u8, data: []const u8, content_type: []const u8) !u64 {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const full_path = try self.pathFor(container, blob);
        defer self.allocator.free(full_path);

        // Ensure container subdirectory exists
        const container_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.workspace, container });
        defer self.allocator.free(container_dir);
        try fs.cwd().makePath(container_dir);

        try fs.cwd().writeFile(.{ .sub_path = full_path, .data = data });

        // Update extent store if entry exists (overwrite)
        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, blob });
        defer self.allocator.free(key);

        if (self.extent_store.get(key)) |existing| {
            self.allocator.free(existing.data);
        }
        try self.extent_store.put(key, .{
            .data = try self.allocator.dupe(u8, data),
            .content_type = try self.allocator.dupe(u8, content_type),
            .created_at = now(),
        });

        return data.len;
    }

    fn get(ctx: *anyopaque, container: []const u8, blob: []const u8, range_start: ?u64, range_end: ?u64) !StorageBackend.GetResult {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const full_path = try self.pathFor(container, blob);
        defer self.allocator.free(full_path);

        const file = fs.cwd().openFile(full_path, .{}) catch return StorageBackend.GetResult{
            .data = &[_]u8{},
            .content_type = "",
            .content_length = 0,
            .etag = "",
            .last_modified = 0,
        };
        defer file.close();

        const stat_info = try file.stat();
        const content_length = stat_info.size;

        const start = range_start orelse 0;
        const end = range_end orelse content_length;

        if (start >= content_length) {
            return StorageBackend.GetResult{
                .data = &[_]u8{},
                .content_type = "",
                .content_length = 0,
                .etag = "",
                .last_modified = @intCast(stat_info.mtime),
            };
        }

        try file.seekTo(start);
        const clamped_end = @min(end, content_length);
        const read_len = clamped_end - start;

        const buf = try self.allocator.alloc(u8, read_len);
        _ = try file.readAll(buf);

        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, blob });
        defer self.allocator.free(key);

        const content_type = if (self.extent_store.get(key)) |entry| entry.content_type else "";

        return StorageBackend.GetResult{
            .data = buf,
            .content_type = content_type,
            .content_length = content_length,
            .etag = try self.etagForPath(full_path),
            .last_modified = @intCast(stat_info.mtime),
        };
    }

    fn stat(ctx: *anyopaque, container: []const u8, blob: []const u8) !StorageBackend.StatResult {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const full_path = try self.pathFor(container, blob);
        defer self.allocator.free(full_path);

        const file = fs.cwd().openFile(full_path, .{}) catch return error.BlobNotFound;
        defer file.close();

        const file_stat = try file.stat();

        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, blob });
        defer self.allocator.free(key);

        const extent = self.extent_store.get(key);
        const content_type = if (extent) |e| e.content_type else "";

        const metadata = std.StringHashMap([]const u8).init(self.allocator);

        return StorageBackend.StatResult{
            .content_type = content_type,
            .content_length = file_stat.size,
            .etag = try self.etagForPath(full_path),
            .last_modified = @intCast(file_stat.mtime),
            .creation_time = @intCast(file_stat.ctime),
            .metadata = metadata,
        };
    }

    fn delete(ctx: *anyopaque, container: []const u8, blob: []const u8) !void {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const full_path = try self.pathFor(container, blob);
        defer self.allocator.free(full_path);

        fs.cwd().deleteFile(full_path) catch {};

        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, blob });
        defer self.allocator.free(key);
        if (self.extent_store.fetchRemove(key)) |kv| {
            self.allocator.free(kv.value.data);
        }
    }

    fn listContainers(ctx: *anyopaque) !StorageBackend.ContainerIterator {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));

        var dir = fs.cwd().openDir(self.workspace, .{ .iterate = true }) catch return StorageBackend.ContainerIterator{
            .items = &[_]StorageBackend.ContainerItem{},
            .index = 0,
        };
        defer dir.close();

        var items = std.ArrayList(StorageBackend.ContainerItem).init(self.allocator);
        defer items.deinit();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            if (mem.eql(u8, entry.name, "$EXTENTS")) continue; // internal marker

            const dir_stat = try dir.statFile(entry.name);
            try items.append(.{
                .name = try self.allocator.dupe(u8, entry.name),
                .last_modified = @intCast(dir_stat.mtime),
                .etag = try self.etagForPath(entry.name),
                .lease_status = "unlocked",
                .lease_state = "available",
            });
        }

        return StorageBackend.ContainerIterator{
            .items = try items.toOwnedSlice(),
            .index = 0,
        };
    }

    fn listBlobs(ctx: *anyopaque, container: []const u8, prefix: []const u8) !StorageBackend.BlobIterator {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));

        const container_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.workspace, container });
        defer self.allocator.free(container_dir);

        var dir = fs.cwd().openDir(container_dir, .{ .iterate = true }) catch return StorageBackend.BlobIterator{
            .items = &[_]StorageBackend.BlobItem{},
            .index = 0,
        };
        defer dir.close();

        var items = std.ArrayList(StorageBackend.BlobItem).init(self.allocator);
        defer items.deinit();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (prefix.len > 0 and !mem.startsWith(u8, entry.name, prefix)) continue;

            const blob_stat = try dir.statFile(entry.name);
            const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, entry.name });
            const extent = self.extent_store.get(key);
            self.allocator.free(key);

            try items.append(.{
                .name = try self.allocator.dupe(u8, entry.name),
                .content_length = @intCast(blob_stat.size),
                .content_type = if (extent) |e| e.content_type else "",
                .etag = try self.allocator.dupe(u8, ""),
                .last_modified = @intCast(blob_stat.mtime),
                .is_committed = true,
                .metadata = std.StringHashMap([]const u8).init(self.allocator),
            });
        }

        // Sort by name
        mem.sort(StorageBackend.BlobItem, items.items, {}, struct {
            fn less(_: void, a: StorageBackend.BlobItem, b: StorageBackend.BlobItem) bool {
                return mem.lessThan(u8, a.name, b.name);
            }
        }.less);

        return StorageBackend.BlobIterator{
            .items = try items.toOwnedSlice(),
            .index = 0,
        };
    }

    fn createContainer(ctx: *anyopaque, container: []const u8) !void {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const container_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.workspace, container });
        defer self.allocator.free(container_dir);
        try fs.cwd().makePath(container_dir);
    }

    fn deleteContainer(ctx: *anyopaque, container: []const u8) !void {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const container_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.workspace, container });
        defer self.allocator.free(container_dir);
        fs.cwd().deleteTree(container_dir) catch {};
    }

    fn containerExists(ctx: *anyopaque, container: []const u8) !bool {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const container_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.workspace, container });
        defer self.allocator.free(container_dir);

        var dir = fs.cwd().openDir(container_dir, .{ .iterate = true }) catch return false;
        dir.close();
        return true;
    }

    fn containerProperties(ctx: *anyopaque, container: []const u8) !StorageBackend.ContainerProperties {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const container_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.workspace, container });
        defer self.allocator.free(container_dir);

        const dir_stat = try fs.cwd().statFile(container_dir);
        _ = dir_stat;

        return StorageBackend.ContainerProperties{
            .last_modified = 0,
            .lease_status = "unlocked",
            .lease_state = "available",
            .public_access = "",
        };
    }

    fn close(ctx: *anyopaque) void {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        var it = self.extent_store.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.data);
        }
        self.extent_store.deinit();
        self.allocator.destroy(self);
    }

    fn etagForPath(self: *FileBackend, path: []const u8) ![]u8 {
        const file = fs.cwd().openFile(path, .{}) catch return "";
        defer file.close();
        const file_stat = try file.stat();
        return std.fmt.allocPrint(self.allocator, "\"{d}\"", .{file_stat.mtime});
    }
};

// ============================================================================================
// MemBackend — in-memory storage for --in-memory mode
// ============================================================================================

pub const MemBackend = struct {
    allocator: mem.Allocator,
    /// container name → container
    containers: std.StringHashMap(Container),
    blobs: std.StringHashMap(BlobEntry),
    extents: std.StringHashMap(ExtentEntry),

    pub const Container = struct {
        created_at: i64,
        properties: StorageBackend.ContainerProperties,
    };

    pub const BlobEntry = struct {
        data: []u8,
        content_type: []const u8,
        created_at: i64,
        last_modified: i64,
        etag: []const u8,
        metadata: std.StringHashMap([]const u8),
    };

    pub const ExtentEntry = struct {
        data: []u8,
        content_type: []const u8,
        created_at: i64,
    };

    pub fn init(allocator: mem.Allocator) MemBackend {
        return .{
            .allocator = allocator,
            .containers = std.StringHashMap(Container).init(allocator),
            .blobs = std.StringHashMap(BlobEntry).init(allocator),
            .extents = std.StringHashMap(ExtentEntry).init(allocator),
        };
    }

    pub fn create(allocator: mem.Allocator) !StorageBackend {
        const backend = init(allocator);
        _ = backend;
        @panic("MemBackend.create not yet implemented");
    }

    fn now() i64 {
        return @intCast(std.time.timestamp());
    }

    fn makeEtag() [36]u8 {
        var buf: [36]u8 = undefined;
        std.fmt.bufPrint(&buf, "{x}-{x}-{x}-{x}-{x}", .{
            std.crypto.random.int(u64),
            std.crypto.random.int(u32),
            std.crypto.random.int(u32),
            std.crypto.random.int(u32),
            std.crypto.random.int(u48),
        }) catch unreachable;
        return buf;
    }
};

// ============================================================================================
// Extent Store — manages uncommitted blocks before PutBlockList commits them
// ============================================================================================

pub const ExtentStore = struct {
    allocator: mem.Allocator,
    /// "container/blob" → array of uncommitted blocks
    pending_blocks: std.StringHashMap(std.ArrayList(UncommittedBlock)),
    /// persisted extent data
    extents: std.StringHashMap([]u8),

    pub const UncommittedBlock = struct {
        id: []const u8,
        data: []u8,
        size: u64,
    };

    pub fn init(allocator: mem.Allocator) ExtentStore {
        return .{
            .allocator = allocator,
            .pending_blocks = std.StringHashMap(std.ArrayList(UncommittedBlock)).init(allocator),
            .extents = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *ExtentStore) void {
        var p_it = self.pending_blocks.iterator();
        while (p_it.next()) |entry| {
            for (entry.value_ptr.items) |block| {
                self.allocator.free(block.data);
            }
            entry.value_ptr.deinit();
        }
        self.pending_blocks.deinit();

        var e_it = self.extents.iterator();
        while (e_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.extents.deinit();
    }

    /// Stage a block for a blob. Returns the block's size.
    pub fn stageBlock(self: *ExtentStore, container: []const u8, blob: []const u8, block_id: []const u8, data: []const u8, _: []const u8) !u64 {
        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, blob });
        defer self.allocator.free(key);

        const blocks = try self.pending_blocks.getOrPut(key);
        if (!blocks.found_existing) {
            blocks.value_ptr.* = std.ArrayList(UncommittedBlock).init(self.allocator);
        }

        try blocks.value_ptr.append(.{
            .id = try self.allocator.dupe(u8, block_id),
            .data = try self.allocator.dupe(u8, data),
            .size = data.len,
        });

        return data.len;
    }

    /// Commit all pending blocks for a blob into a single extent, returns ordered block IDs committed.
    pub fn commitBlocks(self: *ExtentStore, container: []const u8, blob: []const u8, block_list: []const []const u8, _: []const u8) ![]u8 {
        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, blob });
        defer self.allocator.free(key);

        const blocks = self.pending_blocks.get(key) orelse
            return error.NoUncommittedBlocks;

        // Reassemble blocks in order
        var total_size: u64 = 0;
        for (block_list) |block_id| {
            for (blocks.items) |block| {
                if (mem.eql(u8, block.id, block_id)) {
                    total_size += block.size;
                    break;
                }
            }
        }

        var data = try self.allocator.alloc(u8, total_size);
        var offset: u64 = 0;
        for (block_list) |block_id| {
            for (blocks.items) |block| {
                if (mem.eql(u8, block.id, block_id)) {
                    mem.copyForwards(u8, data[offset..], block.data);
                    offset += block.size;
                    break;
                }
            }
        }

        try self.extents.put(key, data);

        // Clear pending blocks
        for (blocks.items) |block| {
            self.allocator.free(block.id);
            self.allocator.free(block.data);
        }
        blocks.clearAndFree();

        return data;
    }

    /// Get uncommitted block IDs for a blob.
    pub fn getUncommittedBlocks(self: *ExtentStore, container: []const u8, blob: []const u8) ![]UncommittedBlock {
        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, blob });
        defer self.allocator.free(key);

        const blocks = self.pending_blocks.get(key) orelse
            return &[_]UncommittedBlock{};
        return blocks.items;
    }
};
