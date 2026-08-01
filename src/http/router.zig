const std = @import("std");
const http = @import("request.zig");

/// HTTP server implementation for Zing.
pub const Server = struct {
    allocator: std.mem.Allocator,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, port: u16) Server {
        return .{ .allocator = allocator, .port = port };
    }

    pub fn deinit(_: *Server) void {}

    pub fn listen(_: *Server) !void {
        return error.NotYetImplemented;
    }
};
