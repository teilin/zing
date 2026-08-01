const std = @import("std");

/// Hexadecimal encode a byte slice into an uppercase hex string.
/// Caller owns the returned slice.
pub fn encode(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const dst = try allocator.alloc(u8, src.len * 2);
    encodeInto(src, dst);
    return dst;
}

/// Encode src into pre-allocated dst (must be src.len * 2 long).
pub fn encodeInto(src: []const u8, dst: []u8) void {
    std.debug.assert(dst.len == src.len * 2);
    const hex_chars = "0123456789ABCDEF".*;
    for (src, 0..) |byte, i| {
        dst[i * 2] = hex_chars[byte >> 4];
        dst[i * 2 + 1] = hex_chars[byte & 0xf];
    }
}

/// Hexadecimal decode an even-length hex string into bytes.
/// Returns an error if the string contains non-hex characters or has odd length.
pub fn decode(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    if (src.len % 2 != 0) return error.InvalidHexLength;
    const dst = try allocator.alloc(u8, src.len / 2);
    errdefer allocator.free(dst);
    try decodeInto(src, dst);
    return dst;
}

/// Decode an even-length hex string into pre-allocated dst (must be src.len/2 long).
pub fn decodeInto(src: []const u8, dst: []u8) !void {
    std.debug.assert(dst.len == src.len / 2);
    if (src.len % 2 != 0) return error.InvalidHexLength;

    for (0..dst.len) |i| {
        const hi = try hexToNibble(src[i * 2]);
        const lo = try hexToNibble(src[i * 2 + 1]);
        dst[i] = (hi << 4) | lo;
    }
}

fn hexToNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A' + 10,
        'a'...'f' => c - 'a' + 10,
        else => error.InvalidHexChar,
    };
}

test "encode decode roundtrip" {
    const allocator = std.testing.allocator;
    const original = "Hello, World!";
    const encoded = try encode(allocator, original);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("48656C6C6F2C20576F726C6421", encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(original, decoded);
}

test "encodeInto" {
    const src = "AB";
    var dst: [4]u8 = undefined;
    encodeInto(src, &dst);
    try std.testing.expectEqualStrings("4142", &dst);
}

test "decodeInto" {
    const src = "4142";
    var dst: [2]u8 = undefined;
    try decodeInto(src, &dst);
    try std.testing.expectEqualStrings("AB", &dst);
}

test "decode invalid char" {
    const allocator = std.testing.allocator;
    const result = decode(allocator, "GG");
    try std.testing.expectError(error.InvalidHexChar, result);
}

test "decode odd length" {
    const allocator = std.testing.allocator;
    const result = decode(allocator, "ABC");
    try std.testing.expectError(error.InvalidHexLength, result);
}
