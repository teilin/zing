const std = @import("std");
const http = @import("http/server.zig");
const storage = @import("storage/backend.zig");
const router_mod = @import("http/router.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI args
    var blob_port: u16 = 10000;
    var workspace_path: []const u8 = "./data";
    var in_memory = false;

    var args_iter = std.process.Args.Iterator.init(init.args);
    defer args_iter.deinit();
    _ = args_iter.skip();
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--blob-port")) {
            blob_port = std.fmt.parseInt(u16, args_iter.next() orelse return error.InvalidPort, 10) catch {
                std.log.err("invalid port: {s}", .{arg});
                return error.InvalidPort;
            };
        } else if (std.mem.eql(u8, arg, "--workspace")) {
            workspace_path = args_iter.next() orelse return error.MissingArg;
        } else if (std.mem.eql(u8, arg, "--in-memory")) {
            in_memory = true;
        }
    }

    std.log.info("Zing Azure Storage Emulator", .{});
    std.log.info("  blob port:   {}", .{blob_port});
    std.log.info("  workspace:   {s}", .{workspace_path});
    std.log.info("  in-memory:   {}", .{in_memory});

    // Initialize storage backend
    var backend = if (in_memory)
        try storage.StorageBackend.initInMemory(allocator)
    else
        try storage.StorageBackend.initFile(allocator, workspace_path);
    defer backend.deinit();

    // Initialize router
    var router = router_mod.Router.init(allocator, backend);

    // Start HTTP server
    var server = try http.Server.init(allocator, blob_port, &router);
    defer server.deinit();

    std.log.info("Zing blob service listening on port {}", .{blob_port});
    try server.listen();
}