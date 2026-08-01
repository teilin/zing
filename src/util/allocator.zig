const std = @import("std");
const builtin = @import("builtin");

/// Arena (bump) allocator — fast linear-allocation allocator that
/// deallocates everything in one shot when reset or freed.
/// NOT thread-safe for concurrent allocation; wrap in a mutex for
/// multi-threaded use.
pub const Arena = struct {
    buffer: []u8,
    offset: usize,
    commit_pos: usize,

    const MIN_ALIGN = 16;

    /// Create a new arena from a pre-allocated buffer.
    /// The buffer must be at least one page in size on supported systems.
    pub fn fromBuffer(buffer: []u8) Arena {
        return .{
            .buffer = buffer,
            .offset = 0,
            .commit_pos = 0,
        };
    }

    /// Allocate `size` bytes aligned to `alignment`.
    /// Returns an error if the arena is exhausted.
    pub fn alloc(ctx: *anyopaque, size: usize, alignment: u29, ret_addr: usize) ![]u8 {
        _ = ret_addr;
        const self: *Arena = @ptrCast(@alignCast(ctx));
        return self.rawAlloc(size, alignment);
    }

    fn rawAlloc(self: *Arena, size: usize, alignment: u29) ![]u8 {
        // Round up current offset to alignment boundary.
        const aligned_offset = std.mem.alignForward usize(self.offset, alignment);
        const new_offset = aligned_offset + size;

        if (new_offset > self.buffer.len) {
            return error.OutOfMemory;
        }

        const result = self.buffer[aligned_offset..new_offset];
        self.offset = new_offset;
        return result;
    }

    /// Free is a no-op for arena; use reset() instead.
    pub fn free(_: *anyopaque, _: []u8, _: u29, _: usize) void {}

    /// Shrink is partially supported — can only shrink from the end
    /// (i.e. undo the last allocation).  We check that the pointer
    /// being freed is exactly at the current end, otherwise we decline.
    pub fn shrink(ctx: *anyopaque, buf: []u8, new_size: usize, alignment: u29, ret_addr: usize) bool {
        const self: *Arena = @ptrCast(@alignCast(ctx));
        _ = alignment;
        _ = ret_addr;
        const current_end = self.offset;
        const buf_end = @intFromPtr(buf.ptr) + buf.len;
        const new_end = @intFromPtr(buf.ptr) + new_size;

        // Only allow shrinking from the tail.
        if (new_end < buf_end and new_end == @intFromPtr(self.buffer.ptr) + current_end) {
            self.offset = new_end;
            return true;
        }
        return false;
    }

    /// Reset the arena to empty — all previously allocated memory is
    /// invalidated.  O(1) operation.
    pub fn reset(self: *Arena) void {
        self.offset = 0;
    }

    /// Return the number of bytes currently allocated.
    pub fn used(self: *const Arena) usize {
        return self.offset;
    }

    /// Return remaining capacity.
    pub fn remaining(self: *const Arena) usize {
        return self.buffer.len - self.offset;
    }
};

/// Wrapper that implements std.mem.Allocator for Arena so it can be
/// passed directly to Zig APIs expecting an Allocator.
pub fn arenaAllocator(arena: *Arena) std.mem.Allocator {
    return .{
        .ptr = arena,
        .vtable = &.{
            .alloc = Arena.alloc,
            .resize = Arena.shrink,
            .free = Arena.free,
        },
    };
}

test "arena basic alloc" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.fromBuffer(&buffer);
    const alloc = arenaAllocator(&arena);

    const a = try alloc.alloc(u8, 64);
    @memset(a, 0xaa);
    try std.testing.expectEqual(@as(usize, 64), a.len);
    try std.testing.expectEqual(@as(usize, 64), arena.used());

    const b = try alloc.alloc(u8, 32);
    @memset(b, 0xbb);
    try std.testing.expectEqual(@as(usize, 96), arena.used());

    // They must be distinct slices.
    try std.testing.expect(a.ptr != b.ptr);
}

test "arena reset" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.fromBuffer(&buffer);
    const alloc = arenaAllocator(&arena);

    _ = try alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), arena.used());

    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.used());

    // After reset we can allocate again from the beginning.
    const c = try alloc.alloc(u8, 50);
    try std.testing.expectEqual(@as(usize, 50), arena.used());
    try std.testing.expectEqual(@as(u8, 0), c[0]); // fresh memory
}

test "arena alignment" {
    var buffer: [256]u8 = undefined;
    var arena = Arena.fromBuffer(&buffer);
    const alloc = arenaAllocator(&arena);

    const a = try alloc.alloc(u8, 1);
    const b = try alloc.alloc(u8, 1);
    // Both must be at least 16-byte aligned.
    try std.testing.expect(@mod(@intFromPtr(a.ptr), 16) == 0);
    try std.testing.expect(@mod(@intFromPtr(b.ptr), 16) == 0);
}

test "arena OOM" {
    var buffer: [32]u8 = undefined;
    var arena = Arena.fromBuffer(&buffer);
    const alloc = arenaAllocator(&arena);

    const result = alloc.alloc(u8, 64);
    try std.testing.expectError(error.OutOfMemory, result);
}
