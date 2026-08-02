const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;

// ============================================================================================
// Pluggable storage backend interface for Zing.
// ============================================================================================

pub const StorageBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (ctx: *anyopaque, container: []const u8, blob: []const u8, data: []const u8, content_type: []const u8) anyerror!u64,
        get: *const fn (ctx: *anyopaque, container: []const u8, blob: []const u8, range_start: ?u64, range_end: ?u64) anyerror!GetResult,
        stat: *const fn (ctx: *anyopaque, container: []const u8, blob: []const u8) anyerror!StatResult,
        delete: *const fn (ctx: *anyopaque, container: []const u8, blob: []const u8) anyerror!void,
        listContainers: *const fn (ctx: *anyopaque) anyerror!ContainerIterator,
        listBlobs: *const fn (ctx: *anyopaque, container: []const u8, prefix: []const u8) anyerror!BlobIterator,
        createContainer: *const fn (ctx: *anyopaque, container: []const u8) anyerror!void,
        deleteContainer: *const fn (ctx: *anyopaque, container: []const u8) anyerror!void,
        containerExists: *const fn (ctx: *anyopaque, container: []const u8) anyerror!bool,
        containerProperties: *const fn (ctx: *anyopaque, container: []const u8) anyerror!ContainerProperties,
        stageBlock: *const fn (ctx: *anyopaque, container: []const u8, blob: []const u8, block_id: []const u8, data: []const u8) anyerror!u64,
        commitBlocks: *const fn (ctx: *anyopaque, container: []const u8, blob: []const u8, block_ids: []const []const u8) anyerror!u64,
        getBlockList: *const fn (ctx: *anyopaque, container: []const u8, blob: []const u8) anyerror!BlockListResult,
        close: *const fn (ctx: *anyopaque) void,
    };

    pub const GetResult = struct {
        data: []const u8,
        content_type: []const u8,
        content_length: u64,
        etag: []const u8,
        last_modified: i64,
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

    pub const BlockItem = struct {
        name: []const u8,
        size: u64,
    };

    pub const BlockListResult = struct {
        committed: []const BlockItem = &.{},
        uncommitted: []const BlockItem = &.{},
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

    pub fn stageBlock(self: StorageBackend, container: []const u8, blob: []const u8, block_id: []const u8, data: []const u8) !u64 {
        return self.vtable.stageBlock(self.ptr, container, blob, block_id, data);
    }

    pub fn commitBlocks(self: StorageBackend, container: []const u8, blob: []const u8, block_ids: []const []const u8) !u64 {
        return self.vtable.commitBlocks(self.ptr, container, blob, block_ids);
    }

    pub fn getBlockList(self: StorageBackend, container: []const u8, blob: []const u8) !BlockListResult {
        return self.vtable.getBlockList(self.ptr, container, blob);
    }

    pub fn initFile(allocator: std.mem.Allocator, workspace: []const u8) !StorageBackend {
        return try FileBackend.create(allocator, workspace);
    }

    pub fn initInMemory(allocator: std.mem.Allocator) !StorageBackend {
        return try MemBackend.create(allocator);
    }

    pub fn deinit(self: StorageBackend) void {
        self.close();
    }
};

// ============================================================================================
// Linux x86_64 struct stat (kernel layout, for raw syscall use).
// ============================================================================================

const Stat = extern struct {
    st_dev: u64,
    st_ino: u64,
    st_nlink: u64,
    st_mode: u32,
    st_uid: u32,
    st_gid: u32,
    __pad0: u32,
    st_rdev: u64,
    st_size: i64,
    st_blksize: i64,
    st_blocks: i64,
    st_atim: extern struct { tv_sec: i64, tv_nsec: i64 },
    st_mtim: extern struct { tv_sec: i64, tv_nsec: i64 },
    st_ctim: extern struct { tv_sec: i64, tv_nsec: i64 },
    __unused: [3]i64,
};

/// Stat a path via the raw fstatat64 (newfstatat) syscall.
/// Returns the kernel-level Stat struct, or a Zig error on failure.
fn statPath(allocator: mem.Allocator, path: []const u8) !Stat {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var st: Stat = undefined;
    const rc = linux.syscall6(
        .fstatat64,
        @as(u64, @bitCast(@as(i64, @as(c_int, linux.AT.FDCWD)))),
        @as(u64, @intFromPtr(path_z.ptr)),
        @as(u64, @intFromPtr(&st)),
        0,
        0,
        0,
    );
    if (@as(i64, @bitCast(rc)) < 0) {
        return errnoToFileError(-@as(c_int, @intCast(@as(i64, @bitCast(rc)))));
    }
    return st;
}

/// Stat an open file descriptor via the raw fstat syscall.
fn statFd(fd: i32) !Stat {
    var st: Stat = undefined;
    const rc = linux.syscall2(
        .fstat,
        @as(u64, @bitCast(@as(i64, fd))),
        @as(u64, @intFromPtr(&st)),
    );
    if (@as(i64, @bitCast(rc)) < 0) {
        return errnoToFileError(-@as(c_int, @intCast(@as(i64, @bitCast(rc)))));
    }
    return st;
}

// ============================================================================================
// Utility: convert errno value to Zig error.
// ============================================================================================

fn errnoToFileError(errno_val: c_int) anyerror {
    return switch (errno_val) {
        13 => error.AccessDenied,
        17 => error.PathAlreadyExists,
        14 => error.BadAddress,
        4 => error.SystemInterrupt,
        22 => error.InvalidArgument,
        5 => error.InputOutput,
        21 => error.IsDir,
        40 => error.SymLinkLoop,
        24 => error.ProcessFdQuotaExceeded,
        36 => error.NameTooLong,
        23 => error.SystemFdQuotaExceeded,
        2 => error.FileNotFound,
        12 => error.SystemResources,
        28 => error.NoSpaceLeft,
        20 => error.NotDir,
        39 => error.DirNotEmpty,
        1 => error.AccessDenied,
        75 => error.FileTooBig,
        30 => error.ReadOnlyFileSystem,
        else => error.Unexpected,
    };
}

/// Helper: check if a usize return from a syscall indicates an error.
/// Syscall wrappers return positive values (or 0) on success, and
/// negative errno values encoded as usize (2's complement).
fn syscallErrno(rc: usize) ?c_int {
    const signed = @as(i64, @bitCast(rc));
    if (signed < 0) return -@as(c_int, @intCast(signed));
    return null;
}

// ============================================================================================
// makePath: recursively create directory components using mkdirat.
// ============================================================================================

fn makePath(allocator: mem.Allocator, path: []const u8) !void {
    if (path.len == 0) return;

    var prefix = try allocator.alloc(u8, path.len);
    defer allocator.free(prefix);
    var prefix_len: usize = 0;

    if (path.len > 0 and path[0] == '/') {
        prefix[0] = '/';
        prefix_len = 1;
    }

    var parts = mem.splitScalar(u8, path, '/');
    while (parts.next()) |comp| {
        if (comp.len == 0) continue;

        if (prefix_len > 0 and prefix[prefix_len - 1] != '/') {
            prefix[prefix_len] = '/';
            prefix_len += 1;
        }
        @memcpy(prefix[prefix_len..][0..comp.len], comp);
        prefix_len += comp.len;

        const component = prefix[0..prefix_len];
        const component_z = try allocator.dupeZ(u8, component);
        defer allocator.free(component_z);

        const rc = linux.mkdirat(linux.AT.FDCWD, component_z, 0o755);
        const err = syscallErrno(rc);
        if (err != null and err.? != 17) { // EEXIST
            return errnoToFileError(err.?);
        }
    }
}

// ============================================================================================
// deleteTree: recursively delete a file or directory tree using unlinkat + getdents64.
// ============================================================================================

fn deleteTree(allocator: mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const dir_fd_rc = linux.openat(linux.AT.FDCWD, path_z, linux.O{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    const dir_fd_err = syscallErrno(dir_fd_rc);
    if (dir_fd_err != null) {
        if (dir_fd_err.? == 2) return; // ENOENT
        return errnoToFileError(dir_fd_err.?);
    }
    const dir_fd: i32 = @intCast(dir_fd_rc);
    defer _ = linux.close(dir_fd);

    var buf: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
    while (true) {
        const n = linux.getdents64(dir_fd, &buf, buf.len);
        const n_err = syscallErrno(n);
        if (n_err != null) return errnoToFileError(n_err.?);
        if (n == 0) break;

        var offset: usize = 0;
        while (offset < n) {
            const dirent = @as(*linux.dirent64, @alignCast(@ptrCast(&buf[offset])));
            const name = @as([*:0]u8, @ptrCast(&dirent.name))[0..std.mem.len(@as([*:0]u8, @ptrCast(&dirent.name)))];
            offset += dirent.reclen;

            if (mem.eql(u8, name, ".") or mem.eql(u8, name, "..")) continue;

            const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
            defer allocator.free(child_path);

            if (dirent.type == 4) { // DT_DIR
                try deleteTree(allocator, child_path);
            } else {
                const child_path_z = try allocator.dupeZ(u8, child_path);
                defer allocator.free(child_path_z);
                _ = linux.unlinkat(linux.AT.FDCWD, child_path_z, 0);
            }
        }
    }
    _ = linux.unlinkat(linux.AT.FDCWD, path_z, linux.AT.REMOVEDIR);
}

// ============================================================================================
// FileBackend — persists blobs as files under a workspace directory
// ============================================================================================

pub const FileBackend = struct {
    workspace: []const u8,
    allocator: mem.Allocator,
    extent_store: std.StringHashMap(ExtentData),
    block_store: ExtentStore,

    pub const ExtentData = struct {
        data: []u8,
        content_type: []const u8,
        created_at: i64,
    };

    pub fn init(allocator: mem.Allocator, workspace: []const u8) !FileBackend {
        try makePath(allocator, workspace);
        return .{
            .workspace = workspace,
            .allocator = allocator,
            .extent_store = std.StringHashMap(ExtentData).init(allocator),
            .block_store = ExtentStore.init(allocator),
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
                                .stageBlock = stageBlock,
                                .commitBlocks = commitBlocks,
                                .getBlockList = getBlockList,
                            },
        };
    }

    fn pathFor(self: *FileBackend, container: []const u8, blob: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.workspace, container, blob });
    }

    fn now() i64 {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.REALTIME, &ts);
        return @intCast(ts.sec);
    }

    fn put(ctx: *anyopaque, container: []const u8, blob: []const u8, data: []const u8, content_type: []const u8) !u64 {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const full_path = try self.pathFor(container, blob);
        defer self.allocator.free(full_path);

        const container_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.workspace, container });
        defer self.allocator.free(container_dir);
        try makePath(self.allocator, container_dir);

        const full_path_z = try self.allocator.dupeZ(u8, full_path);
        defer self.allocator.free(full_path_z);

        const fd_rc = linux.openat(linux.AT.FDCWD, full_path_z, linux.O{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        }, 0o644);
        const fd_err = syscallErrno(fd_rc);
        if (fd_err != null) return errnoToFileError(fd_err.?);
        const fd: i32 = @intCast(fd_rc);
        defer _ = linux.close(fd);

        const written = linux.write(fd, data.ptr, data.len);
        const write_err = syscallErrno(written);
        if (write_err != null) return errnoToFileError(write_err.?);

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

        const full_path_z = try self.allocator.dupeZ(u8, full_path);
        defer self.allocator.free(full_path_z);

        const fd_rc = linux.openat(linux.AT.FDCWD, full_path_z, linux.O{
            .ACCMODE = .RDONLY,
        }, 0);
        const fd_err = syscallErrno(fd_rc);
        if (fd_err != null) {
            return StorageBackend.GetResult{
                .data = &[_]u8{},
                .content_type = "",
                .content_length = 0,
                .etag = "",
                .last_modified = 0,
            };
        }
        const fd: i32 = @intCast(fd_rc);
        defer _ = linux.close(fd);

        const file_stat = try statFd(fd);
        const content_length = @as(u64, @intCast(file_stat.st_size));

        const start = range_start orelse 0;
        const end = range_end orelse content_length;

        if (start >= content_length) {
            return StorageBackend.GetResult{
                .data = &[_]u8{},
                .content_type = "",
                .content_length = 0,
                .etag = "",
                .last_modified = file_stat.st_mtim.tv_sec,
            };
        }

        const seek_rc = linux.lseek(fd, @intCast(start), 0); // SEEK_SET = 0
        if (syscallErrno(seek_rc) != null) return errnoToFileError(syscallErrno(seek_rc).?);

        const clamped_end = @min(end, content_length);
        const read_len = clamped_end - start;

        const buf = try self.allocator.alloc(u8, read_len);
        const n = linux.read(fd, buf.ptr, buf.len);
        if (syscallErrno(n) != null) {
            self.allocator.free(buf);
            return errnoToFileError(syscallErrno(n).?);
        }

        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, blob });
        defer self.allocator.free(key);

        const content_type_str = if (self.extent_store.get(key)) |entry| entry.content_type else "";

        return StorageBackend.GetResult{
            .data = buf,
            .content_type = content_type_str,
            .content_length = content_length,
            .etag = try self.etagForPath(full_path),
            .last_modified = file_stat.st_mtim.tv_sec,
        };
    }

    fn stat(ctx: *anyopaque, container: []const u8, blob: []const u8) !StorageBackend.StatResult {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const full_path = try self.pathFor(container, blob);
        defer self.allocator.free(full_path);

        const file_stat = statPath(self.allocator, full_path) catch {
            return error.BlobNotFound;
        };

        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, blob });
        defer self.allocator.free(key);

        const extent = self.extent_store.get(key);
        const content_type_str = if (extent) |e| e.content_type else "";
        const metadata = std.StringHashMap([]const u8).init(self.allocator);

        return StorageBackend.StatResult{
            .content_type = content_type_str,
            .content_length = @intCast(file_stat.st_size),
            .etag = try self.etagForPath(full_path),
            .last_modified = file_stat.st_mtim.tv_sec,
            .creation_time = file_stat.st_ctim.tv_sec,
            .metadata = metadata,
        };
    }

    fn delete(ctx: *anyopaque, container: []const u8, blob: []const u8) !void {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const full_path = try self.pathFor(container, blob);
        defer self.allocator.free(full_path);

        const full_path_z = try self.allocator.dupeZ(u8, full_path);
        defer self.allocator.free(full_path_z);
        _ = linux.unlinkat(linux.AT.FDCWD, full_path_z, 0);

        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, blob });
        defer self.allocator.free(key);

        if (self.extent_store.fetchRemove(key)) |kv| {
            self.allocator.free(kv.value.data);
        }
    }

    fn listContainers(ctx: *anyopaque) !StorageBackend.ContainerIterator {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));

        const workspace_z = try self.allocator.dupeZ(u8, self.workspace);
        defer self.allocator.free(workspace_z);

        const dir_fd_rc = linux.openat(linux.AT.FDCWD, workspace_z, linux.O{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0);
        const dir_fd_err = syscallErrno(dir_fd_rc);
        if (dir_fd_err != null) {
            return StorageBackend.ContainerIterator{
                .items = &[_]StorageBackend.ContainerItem{},
                .index = 0,
            };
        }
        const dir_fd: i32 = @intCast(dir_fd_rc);
        defer _ = linux.close(dir_fd);

        var items = std.array_list.Managed(StorageBackend.ContainerItem).init(self.allocator);
        defer items.deinit();

        var buf: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
        while (true) {
            const n = linux.getdents64(dir_fd, &buf, buf.len);
            const n_err = syscallErrno(n);
            if (n_err != null) return errnoToFileError(n_err.?);
            if (n == 0) break;

            var offset: usize = 0;
            while (offset < n) {
                const dirent = @as(*linux.dirent64, @alignCast(@ptrCast(&buf[offset])));
                const name = @as([*:0]u8, @ptrCast(&dirent.name))[0..std.mem.len(@as([*:0]u8, @ptrCast(&dirent.name)))];
                offset += dirent.reclen;

                if (dirent.type != 4) continue; // DT_DIR = 4
                if (mem.eql(u8, name, ".") or mem.eql(u8, name, "..")) continue;
                if (mem.eql(u8, name, "$EXTENTS")) continue;

                const dir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.workspace, name });
                defer self.allocator.free(dir_path);

                const dir_stat = statPath(self.allocator, dir_path) catch continue;

                try items.append(.{
                    .name = try self.allocator.dupe(u8, name),
                    .last_modified = dir_stat.st_mtim.tv_sec,
                    .etag = "", // computed lazily if needed
                    .lease_status = "unlocked",
                    .lease_state = "available",
                });
            }
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

        const container_dir_z = try self.allocator.dupeZ(u8, container_dir);
        defer self.allocator.free(container_dir_z);

        const dir_fd_rc = linux.openat(linux.AT.FDCWD, container_dir_z, linux.O{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0);
        const dir_fd_err = syscallErrno(dir_fd_rc);
        if (dir_fd_err != null) {
            return StorageBackend.BlobIterator{
                .items = &[_]StorageBackend.BlobItem{},
                .index = 0,
            };
        }
        const dir_fd: i32 = @intCast(dir_fd_rc);
        defer _ = linux.close(dir_fd);

        var items = std.array_list.Managed(StorageBackend.BlobItem).init(self.allocator);
        defer items.deinit();

        var buf: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
        while (true) {
            const n = linux.getdents64(dir_fd, &buf, buf.len);
            const n_err = syscallErrno(n);
            if (n_err != null) return errnoToFileError(n_err.?);
            if (n == 0) break;

            var offset: usize = 0;
            while (offset < n) {
                const dirent = @as(*linux.dirent64, @alignCast(@ptrCast(&buf[offset])));
                const name = @as([*:0]u8, @ptrCast(&dirent.name))[0..std.mem.len(@as([*:0]u8, @ptrCast(&dirent.name)))];
                offset += dirent.reclen;

                if (dirent.type != 8) continue; // DT_REG = 8
                if (prefix.len > 0 and !mem.startsWith(u8, name, prefix)) continue;

                const blob_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container_dir, name });
                defer self.allocator.free(blob_path);

                const blob_stat = statPath(self.allocator, blob_path) catch continue;

                const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, name });
                defer self.allocator.free(key);

                const extent = self.extent_store.get(key);

                try items.append(.{
                    .name = try self.allocator.dupe(u8, name),
                    .content_length = @intCast(blob_stat.st_size),
                    .content_type = if (extent) |e| e.content_type else "",
                    .etag = try self.allocator.dupe(u8, ""),
                    .last_modified = blob_stat.st_mtim.tv_sec,
                    .is_committed = true,
                    .metadata = std.StringHashMap([]const u8).init(self.allocator),
                });
            }
        }

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
        try makePath(self.allocator, container_dir);
    }

    fn deleteContainer(ctx: *anyopaque, container: []const u8) !void {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const container_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.workspace, container });
        defer self.allocator.free(container_dir);
        deleteTree(self.allocator, container_dir) catch {};
    }

    fn containerExists(ctx: *anyopaque, container: []const u8) !bool {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const container_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.workspace, container });
        defer self.allocator.free(container_dir);

        const container_dir_z = try self.allocator.dupeZ(u8, container_dir);
        defer self.allocator.free(container_dir_z);

        const fd_rc = linux.openat(linux.AT.FDCWD, container_dir_z, linux.O{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0);
        const err = syscallErrno(fd_rc);
        if (err != null) return false;
        _ = linux.close(@intCast(fd_rc));
        return true;
    }

    fn containerProperties(ctx: *anyopaque, container: []const u8) !StorageBackend.ContainerProperties {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const container_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.workspace, container });
        defer self.allocator.free(container_dir);

        const dir_stat = statPath(self.allocator, container_dir) catch {
            return StorageBackend.ContainerProperties{
                .last_modified = 0,
                .lease_status = "unlocked",
                .lease_state = "available",
                .public_access = "",
            };
        };

        return StorageBackend.ContainerProperties{
            .last_modified = dir_stat.st_mtim.tv_sec,
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
        self.block_store.deinit();
        self.allocator.destroy(self);
    }

    fn stageBlock(ctx: *anyopaque, container: []const u8, blob: []const u8, block_id: []const u8, data: []const u8) !u64 {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        return self.block_store.stageBlock(container, blob, block_id, data, "");
    }

    fn commitBlocks(ctx: *anyopaque, container: []const u8, blob: []const u8, block_ids: []const []const u8) !u64 {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const committed_data = try self.block_store.commitBlocks(container, blob, block_ids, "");
        errdefer self.allocator.free(committed_data);
        // Write the assembled blob to disk
        const full_path = try self.pathFor(container, blob);
        defer self.allocator.free(full_path);
        const container_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.workspace, container });
        defer self.allocator.free(container_dir);
        try makePath(self.allocator, container_dir);
        const full_path_z = try self.allocator.dupeZ(u8, full_path);
        defer self.allocator.free(full_path_z);
        const fd_rc = linux.openat(linux.AT.FDCWD, full_path_z, linux.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        const fd_err = syscallErrno(fd_rc);
        if (fd_err != null) return errnoToFileError(fd_err.?);
        const fd: i32 = @intCast(fd_rc);
        defer _ = linux.close(fd);
        const written = linux.write(fd, committed_data.ptr, committed_data.len);
        const write_err = syscallErrno(written);
        if (write_err != null) return errnoToFileError(write_err.?);
        self.allocator.free(committed_data);
        return committed_data.len;
    }

    fn getBlockList(ctx: *anyopaque, container: []const u8, blob: []const u8) !StorageBackend.BlockListResult {
        const self: *FileBackend = @ptrCast(@alignCast(ctx));
        const blocks = try self.block_store.getUncommittedBlocks(container, blob);

        var committed = std.array_list.Managed(StorageBackend.BlockItem).init(self.allocator);
        errdefer committed.deinit();
        var uncommitted = std.array_list.Managed(StorageBackend.BlockItem).init(self.allocator);
        errdefer uncommitted.deinit();

        for (blocks) |block| {
            try uncommitted.append(.{
                .name = block.id,
                .size = block.size,
            });
        }

        // TODO: also read committed blocks from metadata file
        // For now, all staged blocks are uncommitted

        return StorageBackend.BlockListResult{
            .committed = try committed.toOwnedSlice(),
            .uncommitted = try uncommitted.toOwnedSlice(),
        };
    }

    fn etagForPath(self: *FileBackend, path: []const u8) ![]u8 {
        const file_stat = statPath(self.allocator, path) catch {
            return self.allocator.dupe(u8, "");
        };
        return std.fmt.allocPrint(self.allocator, "\"{d}\"", .{file_stat.st_mtim.tv_sec});
    }
};

// ============================================================================================
// MemBackend — in-memory storage for --in-memory mode
// ============================================================================================

pub const MemBackend = struct {
    allocator: mem.Allocator,
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
        _ = init(allocator);
        @panic("MemBackend.create not yet implemented");
    }

    fn now() i64 {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.REALTIME, &ts);
        return @intCast(ts.sec);
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
    pending_blocks: std.StringHashMap(std.array_list.Managed(UncommittedBlock)),
    extents: std.StringHashMap([]u8),

    pub const UncommittedBlock = struct {
        id: []const u8,
        data: []u8,
        size: u64,
    };

    pub fn init(allocator: mem.Allocator) ExtentStore {
        return .{
            .allocator = allocator,
            .pending_blocks = std.StringHashMap(std.array_list.Managed(UncommittedBlock)).init(allocator),
            .extents = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *ExtentStore) void {
        var p_it = self.pending_blocks.iterator();
        while (p_it.next()) |entry| {
            for (entry.value_ptr.items) |block| {
                self.allocator.free(block.data);
                self.allocator.free(block.id);
            }
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending_blocks.deinit();

        var e_it = self.extents.iterator();
        while (e_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.extents.deinit();
    }

    pub fn stageBlock(self: *ExtentStore, container: []const u8, blob: []const u8, block_id: []const u8, data: []const u8, _: []const u8) !u64 {
        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, blob });
        defer self.allocator.free(key);

        const gop = try self.pending_blocks.getOrPut(try self.allocator.dupe(u8, key));
        if (!gop.found_existing) {
            gop.value_ptr.* = std.array_list.Managed(UncommittedBlock).init(self.allocator);
        }

        try gop.value_ptr.append(.{
            .id = try self.allocator.dupe(u8, block_id),
            .data = try self.allocator.dupe(u8, data),
            .size = data.len,
        });

        return data.len;
    }

    pub fn commitBlocks(self: *ExtentStore, container: []const u8, blob: []const u8, block_list: []const []const u8, _: []const u8) ![]u8 {
        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, blob });
        defer self.allocator.free(key);

        const duped_key = try self.allocator.dupe(u8, key);
        defer self.allocator.free(duped_key);

        var blocks = self.pending_blocks.get(duped_key) orelse
            return error.NoUncommittedBlocks;

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

        for (blocks.items) |block| {
            self.allocator.free(block.id);
            self.allocator.free(block.data);
        }
        blocks.clearAndFree();

        return data;
    }

    pub fn getUncommittedBlocks(self: *ExtentStore, container: []const u8, blob: []const u8) ![]UncommittedBlock {
        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ container, blob });
        defer self.allocator.free(key);

        const blocks = self.pending_blocks.get(key) orelse
            return &[_]UncommittedBlock{};
        return blocks.items;
    }
};