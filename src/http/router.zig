const std = @import("std");
const mem = std.mem;
const storage = @import("../storage/backend.zig");
const xml = @import("../xml/serializer.zig");

/// RouteResult returned by the router.
pub const RouteResult = struct {
    status: []const u8,
    body: []const u8,
    content_type: []const u8,
};

/// Router dispatches incoming HTTP requests to the appropriate handler.
pub const Router = struct {
    allocator: std.mem.Allocator,
    backend: storage.StorageBackend,

    pub fn init(allocator: std.mem.Allocator, backend: storage.StorageBackend) Router {
        return .{ .allocator = allocator, .backend = backend };
    }

    /// Route a request to the appropriate handler.
    /// Returns status line, body, and content-type. Caller owns the body slice.
    pub fn route(
        self: *Router,
        method: []const u8,
        path: []const u8,
        headers: std.StringHashMap([]const u8),
        body: []const u8,
    ) !RouteResult {
        _ = headers;

        // Parse path: /account/container/blob
        var segments = mem.splitScalar(u8, path, '/');
        _ = segments.next(); // skip leading empty
        const account = segments.next() orelse return self.notFound();
        _ = account;

        const container = segments.next() orelse {
            // No container — list containers or container-level operations
            return self.handleAccountLevel(method, path);
        };

        const blob = segments.rest();

        // Container-level operations (no blob path)
        if (blob.len == 0) {
            return self.handleContainerLevel(method, container, path);
        }

        // Blob-level operations
        return self.handleBlobLevel(method, container, blob, body);
    }

    fn handleAccountLevel(self: *Router, method: []const u8, path: []const u8) !RouteResult {
        const comp = self.getQueryParam(path, "comp");
        if (mem.eql(u8, method, "GET") and mem.eql(u8, comp orelse "", "list")) {
            return self.listContainers();
        }
        return self.notFound();
    }

    fn handleContainerLevel(self: *Router, method: []const u8, container: []const u8, path: []const u8) !RouteResult {
        const comp = self.getQueryParam(path, "comp");
        const restype = self.getQueryParam(path, "restype");

        if (restype == null or !mem.eql(u8, restype.?, "container")) {
            return self.badRequest("missing restype=container");
        }

        if (mem.eql(u8, method, "PUT") and (comp == null or mem.eql(u8, comp.?, ""))) {
            return self.createContainer(container);
        }
        if (mem.eql(u8, method, "DELETE")) {
            return self.deleteContainer(container);
        }
        if (mem.eql(u8, method, "GET") and (comp == null or mem.eql(u8, comp.?, ""))) {
            return self.getContainerProperties(container);
        }
        if (mem.eql(u8, method, "GET") and mem.eql(u8, comp orelse "", "list")) {
            const prefix = self.getQueryParam(path, "prefix") orelse "";
            return self.listBlobs(container, prefix);
        }
        if (mem.eql(u8, method, "HEAD")) {
            return self.headContainer(container);
        }

        return self.notFound();
    }

    fn handleBlobLevel(self: *Router, method: []const u8, container: []const u8, blob: []const u8, body: []const u8) !RouteResult {
        if (mem.eql(u8, method, "PUT") or mem.eql(u8, method, "PUT")) {
            return self.putBlob(container, blob, body);
        }
        if (mem.eql(u8, method, "GET")) {
            return self.getBlob(container, blob);
        }
        if (mem.eql(u8, method, "HEAD")) {
            return self.headBlob(container, blob);
        }
        if (mem.eql(u8, method, "DELETE")) {
            return self.deleteBlob(container, blob);
        }
        return self.notFound();
    }

    // ── Container handlers ──────────────────────────────────────────────────────

    fn listContainers(self: *Router) !RouteResult {
        var iter = try self.backend.listContainers();

        var ser = xml.Serializer.init(self.allocator);
        defer ser.deinit();

        var container_entries = std.ArrayList(xml.Serializer.ContainerEntry).init(self.allocator);
        defer container_entries.deinit();

        while (iter.next()) |item| {
            // Format last_modified as RFC 1123

            try container_entries.append(.{
                .name = item.name,
                .etag = item.etag,
                .last_modified = "Mon, 01 Jan 2024 00:00:00 GMT",
                .lease_status = item.lease_status,
                .lease_state = item.lease_state,
            });
        }

        const response = xml.Serializer.ListContainersResponse{
            .containers = container_entries.items,
        };

        ser.writeListContainersResponse(&response) catch return self.internalError();
        const xml_body = try self.allocator.dupe(u8, ser.bytes());

        return RouteResult{
            .status = "200 OK",
            .body = xml_body,
            .content_type = "application/xml",
        };
    }

    fn listBlobs(self: *Router, container: []const u8, prefix: []const u8) !RouteResult {
        var iter = try self.backend.listBlobs(container, prefix);

        var ser = xml.Serializer.init(self.allocator);
        defer ser.deinit();

        var blob_entries = std.ArrayList(xml.Serializer.BlobEntry).init(self.allocator);
        defer blob_entries.deinit();

        while (iter.next()) |item| {
            try blob_entries.append(.{
                .name = item.name,
                .properties = .{
                    .last_modified = "Mon, 01 Jan 2024 00:00:00 GMT",
                    .creation_time = "Mon, 01 Jan 2024 00:00:00 GMT",
                    .etag = item.etag,
                    .content_length = item.content_length,
                    .content_type = item.content_type,
                    .blob_type = if (item.is_committed) "BlockBlob" else "BlockBlob",
                },
            });
        }

        const response = xml.Serializer.ListBlobsResponse{
            .prefix = prefix,
            .blobs = blob_entries.items,
        };

        ser.writeListBlobsResponse(&response) catch return self.internalError();
        const xml_body = try self.allocator.dupe(u8, ser.bytes());

        return RouteResult{
            .status = "200 OK",
            .body = xml_body,
            .content_type = "application/xml",
        };
    }

    fn createContainer(self: *Router, container: []const u8) !RouteResult {
        self.backend.createContainer(container) catch return self.internalError();
        return RouteResult{
            .status = "201 Created",
            .body = "",
            .content_type = "",
        };
    }

    fn deleteContainer(self: *Router, container: []const u8) !RouteResult {
        self.backend.deleteContainer(container) catch return self.internalError();
        return RouteResult{
            .status = "202 Accepted",
            .body = "",
            .content_type = "",
        };
    }

    fn getContainerProperties(self: *Router, container: []const u8) !RouteResult {
        _ = self.backend.containerProperties(container) catch return self.notFound();
        return RouteResult{
            .status = "200 OK",
            .body = "",
            .content_type = "",
        };
    }

    fn headContainer(self: *Router, container: []const u8) !RouteResult {
        const exists = self.backend.containerExists(container) catch return self.internalError();
        if (!exists) return self.notFound();
        return RouteResult{
            .status = "200 OK",
            .body = "",
            .content_type = "",
        };
    }

    // ── Blob handlers ───────────────────────────────────────────────────────────

    fn putBlob(self: *Router, container: []const u8, blob: []const u8, data: []const u8) !RouteResult {
        self.backend.createContainer(container) catch {};
        _ = self.backend.put(container, blob, data, "application/octet-stream") catch return self.internalError();
        return RouteResult{
            .status = "201 Created",
            .body = "",
            .content_type = "",
        };
    }

    fn getBlob(self: *Router, container: []const u8, blob: []const u8) !RouteResult {
        const result = self.backend.get(container, blob, null, null) catch return self.internalError();
        defer self.allocator.free(result.data);
        const body = try self.allocator.dupe(u8, result.data);
        return RouteResult{
            .status = "200 OK",
            .body = body,
            .content_type = result.content_type,
        };
    }

    fn headBlob(self: *Router, container: []const u8, blob: []const u8) !RouteResult {
        _ = self.backend.stat(container, blob) catch return self.notFound();
        return RouteResult{
            .status = "200 OK",
            .body = "",
            .content_type = "",
        };
    }

    fn deleteBlob(self: *Router, container: []const u8, blob: []const u8) !RouteResult {
        self.backend.delete(container, blob) catch {};
        return RouteResult{
            .status = "202 Accepted",
            .body = "",
            .content_type = "",
        };
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────

    fn notFound(self: *Router) !RouteResult {
        _ = self;
        return RouteResult{ .status = "404 Not Found", .body = "Not Found", .content_type = "text/plain" };
    }

    fn badRequest(self: *Router, msg: []const u8) !RouteResult {
        _ = self;
        return RouteResult{ .status = "400 Bad Request", .body = msg, .content_type = "text/plain" };
    }

    fn internalError(self: *Router) !RouteResult {
        _ = self;
        return RouteResult{ .status = "500 Internal Server Error", .body = "Internal Server Error", .content_type = "text/plain" };
    }

    fn getQueryParam(self: *Router, path: []const u8, name: []const u8) ?[]const u8 {
        _ = self;
        const qidx = mem.indexOfScalar(u8, path, '?') orelse return null;
        const query = path[qidx + 1 ..];
        var it = mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const val = pair[eq + 1 ..];
            if (mem.eql(u8, key, name)) return val;
        }
        return null;
    }
};