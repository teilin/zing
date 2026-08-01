const std = @import("std");
const posix = std.posix;
const os = std.os;
const builtin = @import("builtin");
const network = std.net;
const mem = std.mem;

const Request = @import("request.zig").Request;
const Router = @import("router.zig").Router;

pub const Server = struct {
    allocator: mem.Allocator,
    sock: posix.socket_t,
    port: u16,
    router: *anyopaque, // placeholder for routing

    pub fn init(allocator: mem.Allocator, port: u16, store: *anyopaque) !*Server {
        _ = store;
        const self = try allocator.create(Server);
        self.* = .{
            .allocator = allocator,
            .sock = try posix.socket(os.AF.INET, os.SOCK.STREAM | os.SOCK.NONBLOCK, 0),
            .port = port,
            .router = undefined,
        };
        errdefer {
            posix.close(self.sock);
            allocator.destroy(self);
        }
        try posix.setsockopt(self.sock, os.SOL.SOCKET, os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
        try posix.bind(self.sock, &network.Address.initIp4(.{127, 0, 0, 1}, port).any);
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
        const epoll_fd = try posix.epoll_create1(0);
        defer posix.close(epoll_fd);

        var ev = mem.zeroes(os.linux.epoll_event);
        ev.events = os.linux.EPOLL.IN | os.linux.EPOLL.ET;
        ev.data.fd = self.sock;
        try os.linux.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL.ADD, self.sock, &ev);

        const events = try self.allocator.alloc(os.linux.epoll_event, 64);
        defer self.allocator.free(events);

        const buf = try self.allocator.alloc(u8, 65536);
        defer self.allocator.free(buf);

        while (true) {
            const n = os.linux.epoll_wait(epoll_fd, events, -1);
            for (events[0..n]) |e| {
                if (e.data.fd == self.sock) {
                    while (true) {
                        const client = posix.accept(self.sock, null, null) catch break;
                        var cev = mem.zeroes(os.linux.epoll_event);
                        cev.events = os.linux.EPOLL.IN | os.linux.EPOLL.ET | os.linux.EPOLL.OUT;
                        cev.data.fd = client;
                        os.linux.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL.ADD, client, &cev) catch {};
                    }
                } else {
                    self.handleClient(e.data.fd, buf) catch {};
                }
            }
        }
    }

    // ─── macOS kqueue ────────────────────────────────────────────────────────
    fn loopKqueue(self: *Server) !void {
        const kq = try posix.kqueue();
        defer posix.close(kq);

        var ev: [1]os.darwin.KEvent = undefined;
        os.darwin.EV_SET(&ev[0], @intCast(self.sock), os.darwin.EVFILT.READ, os.darwin.EV.ADD, 0, 0, null);
        try posix.kevent(kq, &ev, null);

        const events = try self.allocator.alloc(os.darwin.KEvent, 64);
        defer self.allocator.free(events);

        const buf = try self.allocator.alloc(u8, 65536);
        defer self.allocator.free(buf);

        while (true) {
            const n = try posix.kevent(kq, null, events, null);
            for (events[0..n]) |e| {
                if (@as(i32, @intCast(e.ident)) == self.sock) {
                    while (true) {
                        const client = posix.accept(self.sock, null, null) catch break;
                        var cev: [1]os.darwin.KEvent = undefined;
                        os.darwin.EV_SET(&cev[0], @intCast(client), os.darwin.EVFILT.READ, os.darwin.EV.ADD, 0, 0, null);
                        os.darwin.EV_SET(&cev[0], @intCast(client), os.darwin.EVFILT.WRITE, os.darwin.EV.ADD, 0, 0, null);
                        posix.kevent(kq, &cev, null) catch {};
                    }
                } else {
                    self.handleClient(@intCast(e.ident), buf) catch {};
                }
            }
        }
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
        const req = Request.parse(data) catch {
            try posix.write(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\n\r\nBad Request");
            posix.close(client_fd);
            return;
        };

        if (!req.keep_alive) {
            posix.close(client_fd);
        }
        _ = self;
        // req is used implicitly through header parsing — kept for future routing
        _ = req;
    }
};
