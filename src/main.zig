const std = @import("std");
const http = @import("http/server.zig");
const storage = @import("storage/backend.zig");
const router_mod = @import("http/router.zig");
const queue = @import("queue/queue.zig");
const queue_handler = @import("queue/handlers.zig");
const table_mod = @import("table/table.zig");
const table_handler = @import("table/handlers.zig");

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

fn tableRouteFn(ctx: *anyopaque, method: []const u8, path: []const u8, query: []const u8, headers: std.StringHashMap([]const u8), body: []const u8, allocator: std.mem.Allocator) http.RouteResult {
    const router: *table_handler.TableRouter = @ptrCast(@alignCast(ctx));
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

    // Initialize table store
    var table_store = table_mod.TableStore.init(q_allocator);
    defer table_store.deinit();

    // Initialize routers
    var blob_router = router_mod.Router.init(blob_allocator, blob_backend);
    var q_router = queue_handler.QueueRouter.init(q_allocator, &queue_store);
    var t_router = table_handler.TableRouter.init(q_allocator, &table_store);

    // Start servers as background threads
    const Thread = std.Thread;

    var blob_server = try http.Server.init(blob_allocator, blob_port, &blob_router, blobRouteFn);
    defer blob_server.deinit();
    std.log.info("Zing blob service listening on port {}", .{blob_port});
    const blob_thread = try Thread.spawn(.{}, struct {
        fn run(srv: *http.Server) !void { srv.listen() catch |err| std.log.err("blob exited: {}", .{err}); }
    }.run, .{blob_server});
    errdefer blob_thread.detach();

    var q_server = try http.Server.init(q_allocator, queue_port, &q_router, queueRouteFn);
    defer q_server.deinit();
    std.log.info("Zing queue service listening on port {}", .{queue_port});
    const q_thread = try Thread.spawn(.{}, struct {
        fn run(srv: *http.Server) !void { srv.listen() catch |err| std.log.err("queue exited: {}", .{err}); }
    }.run, .{q_server});
    errdefer q_thread.detach();

    // Table server on main thread
    var t_server = try http.Server.init(q_allocator, 10002, &t_router, tableRouteFn);
    defer t_server.deinit();
    std.log.info("Zing table service listening on port 10002", .{});
    t_server.listen() catch |err| {
        std.log.err("table server exited: {}", .{err});
    };

    blob_thread.join();
    q_thread.join();
}