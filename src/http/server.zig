const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const network = std.net;
const mem = std.mem;

const Request = @import("request.zig").Request;
const Router = @import("router.zig").Router;

pub const Server = struct {
    allocator: mem.Allocator,
    sock: posix.socket_t,
    port: u16,
    router: *anyopaque,

    pub fn init(allocator: mem.Allocator, port: u16, store: *anyopaque) !*Server {
        const self = try allocator.create(Server);
        self.* = .{
            .allocator = allocator,
            .sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0),
            .port = port,
            .router = store,
        };
        errdefer {
            posix.close(self.sock);
            allocator.destroy(self);
        }
        try posix.setsockopt(self.sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
        try posix.bind(self.sock, &network.Address.initIp4(.{127, 0, 0, 1}, port).any, @sizeOf(network.Address));
        try posix.listen(self.sock, 128);
        return self;
    }

    pub fn deinit(self: *Server) void {
        posix.close(self.sock);
        self.allocator.destroy(self);
    }

    pub fn listen(self: *Server) !void {
        if (builtin.os.tag == .linux) {
            try self.loopEpoll();
        } else {
            try self.loopKqueue();
        }
    }

    // ─── Linux epoll ────────────────────────────────────────────────────────
    fn loopEpoll(self: *Server) !void {
        const linux = std.os.linux;
        const epoll_fd = try posix.epoll_create1(0);
        defer posix.close(epoll_fd);

        var ev = mem.zeroes(linux.epoll_event);
        ev.events = linux.EPOLL.IN | linux.EPOLL.ET;
        ev.data.fd = self.sock;
        _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, self.sock, &ev);

        const events = try self.allocator.alloc(linux.epoll_event, 64);
        defer self.allocator.free(events);

        const buf = try self.allocator.alloc(u8, 65536);
        defer self.allocator.free(buf);

        while (true) {
            const n = linux.epoll_wait(epoll_fd, events.ptr, @intCast(events.len), -1);
            for (events[0..n]) |e| {
                if (e.data.fd == self.sock) {
                    while (true) {
                        const client = posix.accept(self.sock, null, null, posix.SOCK.NONBLOCK) catch break;
                        var cev = mem.zeroes(linux.epoll_event);
                        cev.events = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.OUT;
                        cev.data.fd = client;
                        _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, client, &cev);
                    }
                } else {
                    self.handleClient(e.data.fd, buf) catch {};
                }
            }
        }
    }

    // ─── macOS kqueue ────────────────────────────────────────────────────────
    fn loopKqueue(self: *Server) !void {
        _ = self;
        @compileError("kqueue not yet implemented for Zig 0.14");
    }

    fn handleClient(self: *Server, client_fd: posix.socket_t, read_buf: []u8) !void {
        const n = posix.read(client_fd, read_buf) catch |err| {
            if (err == error.WouldBlock) return;
            posix.close(client_fd);
            return;
        };
        if (n == 0) {
            posix.close(client_fd);
            return;
        }

        const data = read_buf[0..n];
        var req = Request.parse(self.allocator, data) catch {
            const resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\n\r\nBad Request";
            _ = posix.write(client_fd, resp) catch {};
            posix.close(client_fd);
            return;
        };
        defer req.deinit();

        // Build response via router
        // For now, just echo back that the server is alive
        const router: *Router = @ptrCast(@alignCast(self.router));
        var body: []const u8 = "ok";
        var status: []const u8 = "200 OK";
        var content_type: []const u8 = "text/plain";
        if (router.route(req.method, req.path, req.headers, req.body)) |result| {
            body = result.body;
            status = result.status;
            content_type = result.content_type;
        } else |_| {
            status = "500 Internal Server Error";
            body = "Internal Server Error";
        }
        const hdr = try std.fmt.allocPrint(self.allocator,
            "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n",
            .{ status, content_type, body.len, if (req.keep_alive) "keep-alive" else "close" },
        );
        defer self.allocator.free(hdr);
        _ = posix.write(client_fd, hdr) catch {};
        _ = posix.write(client_fd, body) catch {};

        if (!req.keep_alive) {
            posix.close(client_fd);
        }
    }
};