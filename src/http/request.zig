const std = @import("std");
const mem = std.mem;

/// Parsed HTTP request.
pub const Request = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    keep_alive: bool,
    content_length: u64,

    allocator: std.mem.Allocator,

    /// Parse raw HTTP request bytes into a Request struct.
    /// Caller must call deinit() on the returned request.
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Request {
        var headers = std.StringHashMap([]const u8).init(allocator);
        errdefer headers.deinit();

        // Parse request line: METHOD PATH HTTP/1.1\r\n
        var lines = mem.splitSequence(u8, data, "\r\n");
        const request_line = lines.first();
        var parts = mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse return error.InvalidMethod;
        const full_path = parts.next() orelse return error.InvalidPath;
        _ = parts.next(); // HTTP version

        // Parse path and query
        var path: []const u8 = full_path;
        var query: []const u8 = "";
        if (mem.indexOfScalar(u8, full_path, '?')) |qidx| {
            path = full_path[0..qidx];
            query = full_path[qidx + 1..];
        }

        // Parse headers
        var content_length: u64 = 0;
        var keep_alive = false;
        while (lines.next()) |line| {
            if (line.len == 0) break; // end of headers

            const colon_idx = mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = mem.trim(u8, line[0..colon_idx], " ");
            const value = mem.trim(u8, line[colon_idx + 1 ..], " ");

            // Normalize header name to lowercase
            var name_lower = try allocator.alloc(u8, name.len);
            for (name, 0..) |c, i| name_lower[i] = std.ascii.toLower(c);
            try headers.put(name_lower, try allocator.dupe(u8, value));

            if (mem.eql(u8, name_lower, "content-length")) {
                content_length = std.fmt.parseInt(u64, value, 10) catch 0;
            }
            if (mem.eql(u8, name_lower, "connection")) {
                // Check if connection header contains "keep-alive" (case-insensitive)
                var buf: [64]u8 = undefined;
                const slice = buf[0..@min(value.len, buf.len)];
                _ = std.ascii.lowerString(slice, value[0..slice.len]);
                keep_alive = mem.eql(u8, slice, "keep-alive");
            }
        }

        // Parse body (remaining bytes after headers)
        const header_end = mem.indexOf(u8, data, "\r\n\r\n") orelse return error.InvalidHeaders;
        const body_start = header_end + 4;
        const body_end = @min(body_start + content_length, data.len);
        const body = data[body_start..body_end];

        keep_alive = keep_alive or (content_length > 0); // HTTP/1.1 keep-alive by default

        return Request{
            .method = try allocator.dupe(u8, method),
            .path = try allocator.dupe(u8, path),
            .query = try allocator.dupe(u8, query),
            .headers = headers,
            .body = try allocator.dupe(u8, body),
            .keep_alive = keep_alive,
            .content_length = content_length,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Request) void {
        self.allocator.free(self.method);
        self.allocator.free(self.path);
        self.allocator.free(self.query);
        self.allocator.free(self.body);
        // Free header values
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
    }
};