const std = @import("std");
const http = @import("http/server.zig");
const storage = @import("storage/backend.zig");
const router_mod = @import("http/router.zig");
const queue = @import("queue/queue.zig");
const queue_handler = @import("queue/handlers.zig");

fn blobRouteFn(ctx: *anyopaque, method: []const u8, path: []const u8, query: []const u8, headers: std.StringHashMap([]const u8), body: []const u8, allocator: std.mem.Allocator) http.RouteResult {
    const router: *router_mod.Router = @ptrCast(@alignCast(ctx));
    if (router.route(method, path, query, headers, body)) |result| {
        return .{ .status = result.status, .body = result.body, .content_type = result.content_type };
    } else |_| {
        _ = allocator;
        return .{ .status = "500 Internal Server Error", .body = "Internal Server Error", .content_type = "text/plain" };
    }
}

fn queueRouteFn(ctx: *anyopaque, method: []const u8, path: []const u8, query: []const u8, headers: std.StringHashMap([]const u8), body: []const u8, allocator: std.mem.Allocator) http.RouteResult {
    const router: *queue_handler.QueueRouter = @ptrCast(@alignCast(ctx));
    if (router.route(method, path, query, headers, body)) |result| {
        return .{ .status = result.status, .body = result.body, .content_type = result.content_type };
    } else |_| {
        _ = allocator;
        return .{ .status = "500 Internal Server Error", .body = "Internal Server Error", .content_type = "text/plain" };
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const blob_allocator = std.heap.page_allocator;
    const q_allocator = std.heap.page_allocator;

    // Main allocator only for startup/shared data

    // Parse CLI args
    var blob_port: u16 = 10000;
    var queue_port: u16 = 10001;
    var workspace_path: []const u8 = "./data";
    var in_memory = false;

    var args_iter = std.process.Args.Iterator.init(init.args);
    defer args_iter.deinit();
    _ = args_iter.skip();
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--blob-port")) {
            blob_port = std.fmt.parseInt(u16, args_iter.next() orelse return error.InvalidPort, 10) catch {
                std.log.err("invalid blob port: {s}", .{arg});
                return error.InvalidPort;
            };
        } else if (std.mem.eql(u8, arg, "--queue-port")) {
            queue_port = std.fmt.parseInt(u16, args_iter.next() orelse return error.InvalidPort, 10) catch {
                std.log.err("invalid queue port: {s}", .{arg});
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
    std.log.info("  queue port:  {}", .{queue_port});
    std.log.info("  workspace:   {s}", .{workspace_path});
    std.log.info("  in-memory:   {}", .{in_memory});

    // Initialize storage backend for blobs (uses blob_allocator)
    var blob_backend = if (in_memory)
        try storage.StorageBackend.initInMemory(blob_allocator)
    else
        try storage.StorageBackend.initFile(blob_allocator, workspace_path);
    defer blob_backend.deinit();

    // Initialize queue store with its own allocator
    var queue_store = queue.QueueStore.init(q_allocator);
    defer queue_store.deinit();

    // Initialize routers
    var blob_router = router_mod.Router.init(blob_allocator, blob_backend);
    var q_router = queue_handler.QueueRouter.init(q_allocator, &queue_store);

    // Start blob server (background thread)
    var blob_server = try http.Server.init(blob_allocator, blob_port, &blob_router, blobRouteFn);
    defer blob_server.deinit();
    std.log.info("Zing blob service listening on port {}", .{blob_port});

    // Start queue server (background thread)
    var q_server = try http.Server.init(q_allocator, queue_port, &q_router, queueRouteFn);
    defer q_server.deinit();
    std.log.info("Zing queue service listening on port {}", .{queue_port});

    // Run blob server in background thread, queue server on main thread
    const Thread = std.Thread;
    const blob_thread = try Thread.spawn(.{}, struct {
        fn run(srv: *http.Server) !void {
            srv.listen() catch |err| {
                std.log.err("blob server exited: {}", .{err});
            };
        }
    }.run, .{blob_server});
    errdefer blob_thread.detach();

    q_server.listen() catch |err| {
        std.log.err("queue server exited: {}", .{err});
    };

    blob_thread.join();
}