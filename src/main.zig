const std = @import("std");
const http = @import("http/server.zig");
const storage = @import("storage/backend.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var blob_port: u16 = 10000;
    var workspace_path = ".";
    var in_memory = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--blob-port") and i + 1 < args.len) {
            blob_port = std.fmt.parseInt(u16, args[i + 1], 10) catch {
                std.log.err("invalid port: {s}", .{args[i + 1]});
                return error.InvalidPort;
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--workspace") and i + 1 < args.len) {
            workspace_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--in-memory")) {
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

    // Start HTTP server
    var server = try http.Server.init(allocator, blob_port, &backend);
    defer server.deinit();

    std.log.info("Zing blob service listening on port {}", .{blob_port});
    try server.listen();
}
