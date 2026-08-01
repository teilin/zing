const std = @import("std");
const storage = @import("storage/backend.zig");

/// HTTP server for the Zing object-storage API.
pub const Server = struct {
    allocator: std.mem.Allocator,
    port: u16,
    store: *storage.Storage,

    pub fn init(allocator: std.mem.Allocator, port: u16, store: *storage.Storage) Server {
        return .{ .allocator = allocator, .port = port, .store = store };
    }

    pub fn deinit(_: *Server) void {}

    pub fn listen(_: *Server) !void {
        return error.NotYetImplemented;
    }
};
