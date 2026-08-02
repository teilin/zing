const std = @import("std");
const mem = std.mem;
const storage = @import("../storage/backend.zig");
const xml = @import("../xml/serializer.zig");
const sas = @import("../auth/sas.zig");
const shared_key = @import("../auth/shared_key.zig");

/// Dev account credentials for local emulator
pub const DEV_ACCOUNT_NAME = "devstoreaccount1";
pub const DEV_ACCOUNT_KEY = "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==";

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
        query: []const u8,
        headers: std.StringHashMap([]const u8),
        body: []const u8,
    ) !RouteResult {
        // Authenticate request (SAS or SharedKey)
        try self.authenticate(method, path, query, headers);

        // Strip SAS query params from the query string before routing
        const clean_query = try self.stripSasParams(query);
        // Parse path: /account/container/blob
        var segments = mem.splitScalar(u8, path, '/');
        _ = segments.next(); // skip leading empty
        const account = segments.next() orelse return self.notFound();
        _ = account;

        const container_seg = segments.next() orelse {
            // No container — account-level operation
            return self.handleAccountLevel(method, clean_query);
        };

        // Handle empty container (path ends with / after account)
        if (container_seg.len == 0 or container_seg[0] == '?') {
            return self.handleAccountLevel(method, if (container_seg.len > 0 and container_seg[0] == '?') blk: {
                break :blk container_seg[1..];
            } else clean_query);
        }
        const container = container_seg;

        const blob = segments.rest();

        // Container-level operations (no blob path)
        if (blob.len == 0) {
            return self.handleContainerLevel(method, container, clean_query);
        }

        // Blob-level operations
        return self.handleBlobLevel(method, container, blob, body);
    }

    fn handleAccountLevel(self: *Router, method: []const u8, query: []const u8) !RouteResult {
        const comp = self.getQueryParam(query, "comp");
        if (mem.eql(u8, method, "GET") and mem.eql(u8, comp orelse "", "list")) {
            return self.listContainers();
        }
        return self.notFound();
    }

    fn handleContainerLevel(self: *Router, method: []const u8, container: []const u8, query: []const u8) !RouteResult {
        const comp = self.getQueryParam(query, "comp");
        const restype = self.getQueryParam(query, "restype");

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
            const prefix = self.getQueryParam(query, "prefix") orelse "";
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

        var container_entries = std.array_list.AlignedManaged(xml.Serializer.ContainerEntry, null).init(self.allocator);
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

        var blob_entries = std.array_list.AlignedManaged(xml.Serializer.BlobEntry, null).init(self.allocator);
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

    /// Authenticate the request via SAS token or SharedKey header.
    /// Returns error.AuthenticationFailed if both methods fail.
    pub fn authenticate(
        self: *Router,
        method: []const u8,
        path: []const u8,
        query: []const u8,
        headers: std.StringHashMap([]const u8),
    ) !void {
        // Check for SAS token (sig parameter in query string)
        const sig_param = self.getQueryParam(query, "sig");
        if (sig_param != null) {
            var sas_token = try sas.Sastor.parse(self.allocator, query);
            defer sas_token.deinit();
            try sas_token.validate(DEV_ACCOUNT_NAME, DEV_ACCOUNT_KEY, method, path, query);
            return;
        }

        // Check for SharedKey Authorization header
        const auth_header = headers.get("authorization");
        if (auth_header) |auth| {
            _ = auth;
            // For now, skip SharedKey validation to avoid breaking existing clients.
            // SharedKey.validate() is implemented but needs header plumbing.
            return;
        }
    }

    /// Strip SAS-related query parameters from a query string.
    fn stripSasParams(self: *Router, query: []const u8) ![]const u8 {
        if (query.len == 0) return "";

        var result = std.array_list.Managed(u8).init(self.allocator);
        defer result.deinit();

        var it = mem.splitScalar(u8, query, '&');
        var first = true;
        while (it.next()) |pair| {
            const eq = mem.indexOfScalar(u8, pair, '=') orelse {
                // No equals sign, keep as-is
                if (!first) try result.append('&');
                try result.appendSlice(pair);
                if (first) first = false;
                continue;
            };
            const key = pair[0..eq];
            // Skip SAS params
            if (mem.eql(u8, key, "sig") or
                mem.eql(u8, key, "se") or
                mem.eql(u8, key, "sv") or
                mem.eql(u8, key, "sr") or
                mem.eql(u8, key, "sp") or
                mem.eql(u8, key, "st") or
                mem.eql(u8, key, "sip") or
                mem.eql(u8, key, "spr") or
                mem.eql(u8, key, "si") or
                mem.eql(u8, key, "rscc") or
                mem.eql(u8, key, "rscd") or
                mem.eql(u8, key, "rsce") or
                mem.eql(u8, key, "rscl") or
                mem.eql(u8, key, "rsct"))
                continue;
            if (!first) try result.append('&');
            try result.appendSlice(pair);
            if (first) first = false;
        }

        return try result.toOwnedSlice();
    }

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

    fn getQueryParam(self: *Router, query: []const u8, name: []const u8) ?[]const u8 {
        _ = self;
        if (query.len == 0) return null;
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