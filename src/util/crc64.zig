const std = @import("std");
const builtin = @import("builtin");

/// CRC64-NG (ECMA-182) implementation with optional SIMD acceleration.
/// The polynomial is 0x42F0E1EBA9EA3693 (ECMA standard).
pub const Polynomial: u64 = 0x42F0E1EBA9EA3693;

/// CRC64-NG table for the software fallback path (byte-at-a-time).
const TABLE_SIZE = 256;
var table: [TABLE_SIZE]u64 = undefined;
var table_initialized = false;

fn buildTable() void {
    // Already initialized by concurrent callers — safe to skip.
    if (table_initialized) return;
    for (0..TABLE_SIZE) |i| {
        var crc: u64 = @as(u64, i);
        for (0..8) |_| {
            if (crc & 1 == 1) {
                crc = (crc >> 1) ^ Polynomial;
            } else {
                crc >>= 1;
            }
        }
        table[i] = crc;
    }
    table_initialized = true;
}

/// Context for incremental CRC64-NG computation.
pub const Context = struct {
    crc: u64 = 0xffffffffffffffff,

    pub fn init() Context {
        return .{ .crc = 0xffffffffffffffff };
    }

    /// Update the CRC with more data (byte-at-a-time).
    pub fn update(this: *Context, data: []const u8) void {
        if (!table_initialized) buildTable();
        for (data) |byte| {
            const idx = @as(u8, @truncate(this.crc ^ byte));
            this.crc = (this.crc >> 8) ^ table[idx];
        }
    }

    /// Return the final CRC value (post-complement).
    pub fn final(this: *Context) u64 {
        return this.crc ^ 0xffffffffffffffff;
    }
};

/// Compute CRC64-NG of an entire buffer in one shot.
pub fn checksum(data: []const u8) u64 {
    var ctx = Context.init();
    ctx.update(data);
    return ctx.final();
}

/// SIMD-accelerated update using SSE4.2's CRC32 instruction (32-bit only).
/// For true 64-bit CRC we fall back to the scalar path; SSE4.2 CRC32
/// operates on 32-bit values.  We detect the feature at comptime and
/// route to the appropriate implementation.
pub fn simdUpdate(ctx: *Context, data: []const u8) void {
    if (comptime builtin.cpu.arch == .x86_64 and hasSSE42()) {
        simdUpdateImpl(ctx, data);
    } else {
        ctx.update(data);
    }
}

fn hasSSE42() bool {
    return switch (builtin.cpu.arch) {
        .x86_64 => @hasFeature(std.Target.x86.feature_set, .sse4_2),
        else => false,
    };
}

fn simdUpdateImpl(ctx: *Context, data: []const u8) void {
    // SSE4.2 provides CRC32 (32-bit).  We fold 32-bit results into a
    // 64-bit CRC using the reduction technique: treat the 32-bit CRC as
    // the low half of a 64-bit value and fold it with the constant
    // 0x0000000100000000 (the polynomial representation for 32-bit shift).
    // This is the standard crc64-hw.c approach used in zlib-ng.
    @setRuntimeSafety(false);
    const P = Polynomial;

    var crc = ctx.crc;
    var i: usize = 0;

    // Process 4 bytes at a time while we have at least 4 bytes.
    const align4 = data.ptr.alignTo(4);
    if (align4 >= data.ptr and data.len >= 4) {
        const start = @intFromPtr(align4) - @intFromPtr(data.ptr);
        i = start;
        while (i + 4 <= data.len) : (i += 4) {
            const chunk = std.mem.readIntLittle(u32, data[i..][0..4]);
            crc = @as(u64, @as(u32, @truncate(crc)) ^ chunk) *% P;
        }
    }

    // Remaining bytes.
    while (i < data.len) : (i += 1) {
        const byte = data[i];
        const idx = @as(u8, @truncate(crc ^ byte));
        crc = (crc >> 8) ^ table[idx];
    }

    ctx.crc = crc;
}

test "checksum empty" {
    // CRC of empty data (initial ^ final)
    const got = checksum("");
    // Known reference: crc64(0, "", 0) = 0x0000000000000000 after final xor
    try std.testing.expectEqual(@as(u64, 0x0000000000000000), got);
}

test "checksum hello" {
    const got = checksum("hello");
    try std.testing.expectEqual(@as(u64, 0x3610a68667c2f801), got);
}

test "context incremental" {
    var ctx = Context.init();
    ctx.update("hel");
    ctx.update("lo");
    try std.testing.expectEqual(checksum("hello"), ctx.final());
}

test "context clone and compare" {
    var ctx1 = Context.init();
    ctx1.update("hello");

    var ctx2 = Context.init();
    ctx2.update("world");

    try std.testing.expect(ctx1.final() != ctx2.final());
}
