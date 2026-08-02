const std = @import("std");
const c = std.c;
const builtin = @import("builtin");
const mem = std.mem;

const Request = @import("request.zig").Request;

pub const RouteResult = struct { status: []const u8, body: []const u8, content_type: []const u8 };

/// Function type for request handling. Returns (status, body, content_type).
const RouteFn = *const fn (anyopaque: *anyopaque, method: []const u8, path: []const u8, query: []const u8, headers: std.StringHashMap([]const u8), body: []const u8, allocator: std.mem.Allocator) RouteResult;

pub const Server = struct {
    allocator: std.mem.Allocator,
    sock: c.fd_t,
    port: u16,
    handle_ctx: *anyopaque,
    route_fn: RouteFn,

    fn cErr(errno_val: c_int) anyerror {
        return switch (errno_val) {
            @as(c_int, 13) => error.AccessDenied,
            @as(c_int, 98) => error.AddressInUse,
            @as(c_int, 97) => error.AddressFamilyNotSupported,
            @as(c_int, 11) => error.WouldBlock,
            @as(c_int, 114) => error.ConnectionPending,
            @as(c_int, 9) => error.BadFileDescriptor,
            @as(c_int, 111) => error.ConnectionRefused,
            @as(c_int, 104) => error.ConnectionResetByPeer,
            @as(c_int, 14) => error.BadAddress,
            @as(c_int, 4) => error.SystemInterrupt,
            @as(c_int, 22) => error.InvalidArgument,
            @as(c_int, 5) => error.InputOutput,
            @as(c_int, 24) => error.ProcessFdQuotaExceeded,
            @as(c_int, 23) => error.SystemFdQuotaExceeded,
            @as(c_int, 12) => error.SystemResources,
            @as(c_int, 28) => error.NoSpaceLeft,
            @as(c_int, 20) => error.NotDir,
            @as(c_int, 2) => error.FileNotFound,
            @as(c_int, 88) => error.NotSocket,
            @as(c_int, 1) => error.AccessDenied,
            @as(c_int, 32) => error.BrokenPipe,
            @as(c_int, 99) => error.AddressNotAvailable,
            @as(c_int, 95) => error.OperationNotSupported,
            @as(c_int, 90) => error.MessageTooBig,
            else => error.Unexpected,
        };
    }

    pub fn init(allocator: mem.Allocator, port: u16, ctx: *anyopaque, route_fn: RouteFn) !*Server {
        const self = try allocator.create(Server);

        const sock = c.socket(c.AF.INET, @as(c_int, 1) | @as(c_int, 0o4000), 0);
        if (sock == -1) {
            allocator.destroy(self);
            return cErr(c._errno().*);
        }
        errdefer _ = c.close(sock);

        const optval: c_int = 1;
        if (c.setsockopt(sock, @as(c_int, 1), @as(c_int, 2), &optval, @sizeOf(c_int)) == -1) {
            allocator.destroy(self);
            return cErr(c._errno().*);
        }

        var addr = std.os.linux.sockaddr.in{
            .family = c.AF.INET,
            .port = mem.nativeToBig(u16, port),
            .addr = mem.nativeToBig(u32, 0x7f000001),
            .zero = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
        };
        if (c.bind(sock, @as(*const c.sockaddr, @ptrCast(&addr)), @sizeOf(@TypeOf(addr))) == -1) {
            allocator.destroy(self);
            return cErr(c._errno().*);
        }

        if (c.listen(sock, 128) == -1) {
            allocator.destroy(self);
            return cErr(c._errno().*);
        }

        self.* = .{
            .allocator = allocator,
            .sock = sock,
            .port = port,
            .handle_ctx = ctx,
            .route_fn = route_fn,
        };
        return self;
    }

    pub fn deinit(self: *Server) void {
        _ = c.close(self.sock);
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
        const epoll_fd = c.epoll_create1(0);
        if (epoll_fd == -1) return cErr(c._errno().*);
        defer _ = c.close(epoll_fd);

        var ev = mem.zeroes(c.epoll_event);
        ev.events = @as(u32, 0x001) | @as(u32, 0x80000000);
        ev.data.fd = self.sock;
        if (c.epoll_ctl(epoll_fd, @as(u32, 1), self.sock, &ev) == -1) {
            return cErr(c._errno().*);
        }

        const events = try self.allocator.alloc(c.epoll_event, 64);
        defer self.allocator.free(events);

        const buf = try self.allocator.alloc(u8, 65536);
        defer self.allocator.free(buf);

        while (true) {
            const n = c.epoll_wait(epoll_fd, events.ptr, @intCast(events.len), -1);
            if (n == -1) return cErr(c._errno().*);
            for (events[0..@intCast(n)]) |e| {
                if (e.data.fd == self.sock) {
                    while (true) {
                        const client = c.accept4(self.sock, null, null, @as(c_int, 0o4000));
                        if (client == -1) break;
                        var cev = mem.zeroes(c.epoll_event);
                        cev.events = @as(u32, 0x001) | @as(u32, 0x80000000) | @as(u32, 0x004);
                        cev.data.fd = client;
                        _ = c.epoll_ctl(epoll_fd, @as(u32, 1), client, &cev);
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
        @compileError("kqueue not yet implemented for Zig 0.16");
    }

    fn handleClient(self: *Server, client_fd: c.fd_t, read_buf: []u8) !void {
        const n = c.read(client_fd, read_buf.ptr, read_buf.len);
        if (n == -1) {
            const err = c._errno().*;
            if (err == @as(c_int, 11) or err == @as(c_int, 11)) return;
            _ = c.close(client_fd);
            return;
        }
        if (n == 0) {
            _ = c.close(client_fd);
            return;
        }

        const data = read_buf[0..@intCast(n)];
        var req = Request.parse(self.allocator, data) catch {
            const resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\n\r\nBad Request";
            _ = c.write(client_fd, resp.ptr, resp.len);
            _ = c.close(client_fd);
            return;
        };
        defer req.deinit();

        // Build response via router
        var body: []const u8 = "ok";
        var status: []const u8 = "200 OK";
        var content_type: []const u8 = "text/plain";
        const result = self.route_fn(self.handle_ctx, req.method, req.path, req.query, req.headers, req.body, self.allocator);
        body = result.body;
        status = result.status;
        content_type = result.content_type;
        const hdr = try std.fmt.allocPrint(self.allocator,
            "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n",
            .{ status, content_type, body.len, if (req.keep_alive) "keep-alive" else "close" },
        );
        defer self.allocator.free(hdr);
        _ = c.write(client_fd, hdr.ptr, hdr.len);
        _ = c.write(client_fd, body.ptr, body.len);

        if (!req.keep_alive) {
            _ = c.close(client_fd);
        }
    }
};