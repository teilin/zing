const std = @import("std");
const mem = std.mem;
const testing = std.testing;

/// XML serializer for Azure Storage REST API responses.
///
/// Produces XML in the format required by Azure Storage API versions 2024-11-04
/// and earlier. Handles: ListContainers, ListBlobs, GetBlockList, error responses.

pub const Serializer = struct {
    allocator: mem.Allocator,
    buf: std.ArrayList(u8),

    pub fn init(allocator: mem.Allocator) Serializer {
        return .{
            .allocator = allocator,
            .buf = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Serializer) void {
        self.buf.deinit();
    }

    /// Returns the serialized XML bytes. Valid until deinit or reset.
    pub fn bytes(self: *const Serializer) []const u8 {
        return self.buf.items;
    }

    /// Reset the buffer for reuse.
    pub fn reset(self: *Serializer) void {
        self.buf.clearRetainingCapacity();
    }

    fn writeElemOpen(self: *Serializer, name: []const u8) !void {
        try self.buf.writer().print("<{s}", .{name});
    }

    fn writeAttrib(self: *Serializer, name: []const u8, value: []const u8) !void {
        // XML attribute values must be escaped
        try self.buf.writer().print(" {s}=\"", .{name});
        try self.escape(value, .attribute);
        try self.buf.writer().print("\"", .{});
    }

    fn writeAttribInt(self: *Serializer, name: []const u8, value: anytype) !void {
        try self.buf.writer().print(" {s}=\"{}\"", .{ name, value });
    }

    fn writeCloseTag(self: *Serializer, name: []const u8) !void {
        try self.buf.writer().print("</{s}>", .{name});
    }

    fn writeOpenTag(self: *Serializer, name: []const u8) !void {
        try self.buf.writer().print("<{s}>", .{name});
    }

    fn writeOpenTagNs(self: *Serializer, ns: []const u8, name: []const u8) !void {
        try self.buf.writer().print("<{s}:{s}>", .{ ns, name });
    }

    fn writeCloseTagNs(self: *Serializer, ns: []const u8, name: []const u8) !void {
        try self.buf.writer().print("</{s}:{s}>", .{ ns, name });
    }

    fn writeEmptyTag(self: *Serializer, name: []const u8) !void {
        try self.buf.writer().print("<{s} />", .{name});
    }

    fn writeText(self: *Serializer, text: []const u8) !void {
        try self.escape(text, .text);
    }

    fn writeTextInt(self: *Serializer, value: anytype) !void {
        try self.buf.writer().print("{}", .{value});
    }

    fn writeTextBool(self: *Serializer, value: bool) !void {
        try self.buf.writer().print("{s}", .{if (value) "true" else "false"});
    }

    fn nl(self: *Serializer) !void {
        try self.buf.append('\n');
    }

    fn escape(self: *Serializer, text: []const u8, mode: EscapeMode) !void {
        // Azure Storage XML uses UTF-8. Escape special XML characters.
        for (text) |ch| {
            switch (ch) {
                '&' => try self.buf.appendSlice("&amp;"),
                '<' => try self.buf.appendSlice("&lt;"),
                '>' => try self.buf.appendSlice("&gt;"),
                '"' => if (mode == .attribute) try self.buf.appendSlice("&quot;"),
                '\'' => if (mode == .attribute) try self.buf.appendSlice("&apos;"),
                else => try self.buf.append(ch),
            }
        }
    }

    const EscapeMode = enum { text, attribute };

    // ========================================================================================
    // ListContainersResponse
    // ========================================================================================

    pub const ListContainersResponse = struct {
        prefix: []const u8 = "",
        marker: []const u8 = "",
        max_results: u32 = 5000,
        containers: []const ContainerEntry = &.{},
        next_marker: []const u8 = "",
        request_id: []const u8 = "",
        version: []const u8 = "2024-11-04",
        date: []const u8 = "",
    };

    pub const ContainerEntry = struct {
        name: []const u8,
        etag: []const u8,
        last_modified: []const u8,
        lease_status: []const u8 = "unlocked",
        lease_state: []const u8 = "available",
        public_access: []const u8 = "",
        has_immutability_policy: bool = false,
        has_deleted: bool = false,
    };

    pub fn writeListContainersResponse(self: *Serializer, resp: *const ListContainersResponse) !void {
        self.reset();
        try self.buf.writer().print(
            \\<?xml version="1.0" encoding="utf-8"?>
        , .{});
        try self.nl();
        try self.writeOpenTag("EnumerationResults");
        try self.writeAttrib("AccountName", "devstoreaccount1");
        try self.buf.writer().print(">", .{});
        try self.nl();

        // Helper: write an optional element only when value is non-empty
        const opt2 = struct {
            fn write(s: *Serializer, tag: []const u8, val: []const u8) !void {
                if (val.len > 0) {
                    try s.writeOpenTag(tag);
                    try s.writeText(val);
                    try s.writeCloseTag(tag);
                    try s.nl();
                }
            }
        };

        try opt2.write(self, "Prefix", resp.prefix);
        try opt2.write(self, "Marker", resp.marker);
        if (resp.max_results > 0) {
            try self.writeOpenTag("MaxResults");
            try self.writeTextInt(resp.max_results);
            try self.writeCloseTag("MaxResults");
            try self.nl();
        }

        try self.writeOpenTag("Containers");
        try self.nl();
        for (resp.containers) |c| {
            try self.writeOpenTag("Container");
            try self.nl();
            {
                try self.writeOpenTag("Name");
                try self.writeText(c.name);
                try self.writeCloseTag("Name");
                try self.nl();

                try self.writeOpenTag("Properties");
                try self.nl();
                {
                    try self.writeOpenTag("Last-Modified");
                    try self.writeText(c.last_modified);
                    try self.writeCloseTag("Last-Modified");
                    try self.nl();

                    try self.writeOpenTag("Etag");
                    try self.writeText(c.etag);
                    try self.writeCloseTag("Etag");
                    try self.nl();

                    try self.writeOpenTag("LeaseStatus");
                    try self.writeText(c.lease_status);
                    try self.writeCloseTag("LeaseStatus");
                    try self.nl();

                    try self.writeOpenTag("LeaseState");
                    try self.writeText(c.lease_state);
                    try self.writeCloseTag("LeaseState");
                    try self.nl();

                    try self.writeOpenTag("PublicAccess");
                    try self.writeText(c.public_access);
                    try self.writeCloseTag("PublicAccess");
                    try self.nl();

                    try self.writeOpenTag("HasImmutabilityPolicy");
                    try self.writeTextBool(c.has_immutability_policy);
                    try self.writeCloseTag("HasImmutabilityPolicy");
                    try self.nl();

                    try self.writeOpenTag("Deleted");
                    try self.writeTextBool(c.has_deleted);
                    try self.writeCloseTag("Deleted");
                    try self.nl();
                }
                try self.writeCloseTag("Properties");
                try self.nl();
            }
            try self.writeCloseTag("Container");
            try self.nl();
        }
        try self.writeCloseTag("Containers");
        try self.nl();

        if (resp.next_marker.len > 0) {
            try self.writeOpenTag("NextMarker");
            try self.writeText(resp.next_marker);
            try self.writeCloseTag("NextMarker");
            try self.nl();
        }

        try self.writeOpenTag("ResponseMetadata");
        try self.nl();
        {
            try self.writeOpenTag("RequestId");
            try self.writeText(resp.request_id);
            try self.writeCloseTag("RequestId");
            try self.nl();
            try self.writeOpenTag("Version");
            try self.writeText(resp.version);
            try self.writeCloseTag("Version");
            try self.nl();
            try self.writeOpenTag("Date");
            try self.writeText(resp.date);
            try self.writeCloseTag("Date");
            try self.nl();
        }
        try self.writeCloseTag("ResponseMetadata");
        try self.nl();

        try self.writeCloseTag("EnumerationResults");
        try self.nl();
    }

    // ========================================================================================
    // ListBlobsResponse
    // ========================================================================================

    pub const ListBlobsResponse = struct {
        prefix: []const u8 = "",
        marker: []const u8 = "",
        max_results: u32 = 5000,
        blobs: []const BlobEntry = &.{},
        next_marker: []const u8 = "",
        request_id: []const u8 = "",
        version: []const u8 = "2024-11-04",
        date: []const u8 = "",
    };

    pub const BlobEntry = struct {
        name: []const u8,
        snapshot: []const u8 = "",
        version_id: []const u8 = "",
        is_current_version: bool = true,
        is_deleted: bool = false,
        properties: BlobProperties,
        metadata: []const struct { name: []const u8, value: []const u8 } = &.{},
    };

    pub const BlobProperties = struct {
        last_modified: []const u8,
        creation_time: []const u8 = "",
        etag: []const u8,
        content_length: u64,
        content_type: []const u8 = "application/octet-stream",
        content_encoding: []const u8 = "",
        content_language: []const u8 = "",
        content_md5: []const u8 = "",
        content_disposition: []const u8 = "",
        cache_control: []const u8 = "",
        blob_type: []const u8 = "BlockBlob",
        sequence_number: u64 = 0,
        committed_block_count: ?u32 = null,
        access_tier: []const u8 = "Hot",
        access_tier_inferred: bool = true,
        lease_status: []const u8 = "unlocked",
        lease_state: []const u8 = "available",
        lease_duration: []const u8 = "",
        copy_id: []const u8 = "",
        copy_status: []const u8 = "",
        copy_source: []const u8 = "",
        copy_progress: []const u8 = "",
        copy_completion_time: []const u8 = "",
        access_tier_change_time: []const u8 = "",
    };

    pub fn writeListBlobsResponse(self: *Serializer, resp: *const ListBlobsResponse) !void {
        self.reset();
        try self.buf.writer().print(
            \\<?xml version="1.0" encoding="utf-8"?>
        , .{});
        try self.nl();
        try self.writeOpenTag("EnumerationResults");
        try self.writeAttrib("ServiceEndpoint", "http://127.0.0.1:10000/devstoreaccount1/");
        try self.buf.writer().print(">", .{});
        try self.nl();

        // Helper: write an optional element only when value is non-empty
        const opt2 = struct {
            fn write(s: *Serializer, tag: []const u8, val: []const u8) !void {
                if (val.len > 0) {
                    try s.writeOpenTag(tag);
                    try s.writeText(val);
                    try s.writeCloseTag(tag);
                    try s.nl();
                }
            }
        };

        try opt2.write(self, "Prefix", resp.prefix);
        try opt2.write(self, "Marker", resp.marker);
        if (resp.max_results > 0) {
            try self.writeOpenTag("MaxResults");
            try self.writeTextInt(resp.max_results);
            try self.writeCloseTag("MaxResults");
            try self.nl();
        }

        try self.writeOpenTag("Blobs");
        try self.nl();

        // Blob elements
        for (resp.blobs) |blob| {
            try self.writeOpenTag("Blob");
            try self.nl();

            // Blob tag (name)
            {
                try self.writeOpenTag("Name");
                try self.writeText(blob.name);
                try self.writeCloseTag("Name");
                try self.nl();

                if (blob.snapshot.len > 0) {
                    try self.writeOpenTag("Snapshot");
                    try self.writeText(blob.snapshot);
                    try self.writeCloseTag("Snapshot");
                    try self.nl();
                }

                if (blob.version_id.len > 0) {
                    try self.writeOpenTag("VersionId");
                    try self.writeText(blob.version_id);
                    try self.writeCloseTag("VersionId");
                    try self.nl();
                }

                try self.writeOpenTag("Properties");
                try self.nl();
                {
                    const p = blob.properties;
                    try opt2.write(self, "Last-Modified", p.last_modified);
                    try opt2.write(self, "Creation-Time", p.creation_time);
                    try opt2.write(self, "Etag", p.etag);

                    try self.writeOpenTag("Content-Length");
                    try self.writeTextInt(p.content_length);
                    try self.writeCloseTag("Content-Length");
                    try self.nl();

                    try opt2.write(self, "Content-Type", p.content_type);
                    try opt2.write(self, "Content-Encoding", p.content_encoding);
                    try opt2.write(self, "Content-Language", p.content_language);
                    try opt2.write(self, "Content-MD5", p.content_md5);
                    try opt2.write(self, "Content-Disposition", p.content_disposition);
                    try opt2.write(self, "Cache-Control", p.cache_control);

                    try self.writeOpenTag("BlobType");
                    try self.writeText(p.blob_type);
                    try self.writeCloseTag("BlobType");
                    try self.nl();

                    try self.writeOpenTag("SequenceNumber");
                    try self.writeTextInt(p.sequence_number);
                    try self.writeCloseTag("SequenceNumber");
                    try self.nl();

                    if (p.committed_block_count) |cnt| {
                        try self.writeOpenTag("CommittedBlockCount");
                        try self.writeTextInt(cnt);
                        try self.writeCloseTag("CommittedBlockCount");
                        try self.nl();
                    }

                    try opt2.write(self, "AccessTier", p.access_tier);

                    try self.writeOpenTag("AccessTierInferred");
                    try self.writeTextBool(p.access_tier_inferred);
                    try self.writeCloseTag("AccessTierInferred");
                    try self.nl();

                    try opt2.write(self, "LeaseStatus", p.lease_status);
                    try opt2.write(self, "LeaseState", p.lease_state);
                    try opt2.write(self, "LeaseDuration", p.lease_duration);

                    if (!blob.is_current_version) {
                        try self.writeOpenTag("IsCurrentVersion");
                        try self.writeTextBool(blob.is_current_version);
                        try self.writeCloseTag("IsCurrentVersion");
                        try self.nl();
                    }

                    if (blob.is_deleted) {
                        try self.writeOpenTag("Deleted");
                        try self.writeTextBool(blob.is_deleted);
                        try self.writeCloseTag("Deleted");
                        try self.nl();
                    }

                    try opt2.write(self, "CopyId", p.copy_id);
                    try opt2.write(self, "CopyStatus", p.copy_status);
                    try opt2.write(self, "CopySource", p.copy_source);
                    try opt2.write(self, "CopyProgress", p.copy_progress);
                    try opt2.write(self, "CopyCompletionTime", p.copy_completion_time);
                    try opt2.write(self, "AccessTierChangeTime", p.access_tier_change_time);
                }
                try self.writeCloseTag("Properties");
                try self.nl();

                // Metadata
                if (blob.metadata.len > 0) {
                    try self.writeOpenTag("Metadata");
                    try self.nl();
                    for (blob.metadata) |m| {
                        try self.writeOpenTag(m.name);
                        try self.writeText(m.value);
                        try self.writeCloseTag(m.name);
                        try self.nl();
                    }
                    try self.writeCloseTag("Metadata");
                    try self.nl();
                }
            }

            try self.writeCloseTag("Blob");
            try self.nl();
        }

        // BlobPrefix for directory-style listing
        // (omitted for simplicity — Azure SDK handles prefix traversal via NextMarker)

        try self.writeCloseTag("Blobs");
        try self.nl();

        if (resp.next_marker.len > 0) {
            try self.writeOpenTag("NextMarker");
            try self.writeText(resp.next_marker);
            try self.writeCloseTag("NextMarker");
            try self.nl();
        }

        try self.writeOpenTag("ResponseMetadata");
        try self.nl();
        {
            try self.writeOpenTag("RequestId");
            try self.writeText(resp.request_id);
            try self.writeCloseTag("RequestId");
            try self.nl();
            try self.writeOpenTag("Version");
            try self.writeText(resp.version);
            try self.writeCloseTag("Version");
            try self.nl();
        }
        try self.writeCloseTag("ResponseMetadata");
        try self.nl();

        try self.writeCloseTag("EnumerationResults");
        try self.nl();
    }

    // ========================================================================================
    // GetBlockListResponse
    // ========================================================================================

    pub const GetBlockListResponse = struct {
        request_id: []const u8 = "",
        version: []const u8 = "2024-11-04",
        date: []const u8 = "",
        blocks: BlockList,
    };

    pub const BlockList = struct {
        committed: []const Block = &.{},
        uncommitted: []const Block = &.{},
    };

    pub const Block = struct {
        id: []const u8,
        length: u64,
        offset: u64 = 0,
    };

    pub fn writeGetBlockListResponse(self: *Serializer, resp: *const GetBlockListResponse) !void {
        self.reset();
        try self.buf.writer().print(
            \\<?xml version="1.0" encoding="utf-8"?>
        , .{});
        try self.nl();
        try self.writeOpenTag("BlockList");
        try self.writeAttrib("ServiceEndpoint", "http://127.0.0.1:10000/devstoreaccount1/");
        try self.buf.writer().print(">", .{});
        try self.nl();

        if (resp.blocks.committed.len > 0) {
            try self.writeOpenTag("CommittedBlocks");
            try self.nl();
            for (resp.blocks.committed) |b| {
                try self.writeOpenTag("Block");
                try self.nl();
                {
                    try self.writeOpenTag("Name");
                    try self.writeText(b.id);
                    try self.writeCloseTag("Name");
                    try self.nl();
                    try self.writeOpenTag("Size");
                    try self.writeTextInt(b.length);
                    try self.writeCloseTag("Size");
                    try self.nl();
                }
                try self.writeCloseTag("Block");
                try self.nl();
            }
            try self.writeCloseTag("CommittedBlocks");
            try self.nl();
        }

        if (resp.blocks.uncommitted.len > 0) {
            try self.writeOpenTag("UncommittedBlocks");
            try self.nl();
            for (resp.blocks.uncommitted) |b| {
                try self.writeOpenTag("Block");
                try self.nl();
                {
                    try self.writeOpenTag("Name");
                    try self.writeText(b.id);
                    try self.writeCloseTag("Name");
                    try self.nl();
                    try self.writeOpenTag("Size");
                    try self.writeTextInt(b.length);
                    try self.writeCloseTag("Size");
                    try self.nl();
                }
                try self.writeCloseTag("Block");
                try self.nl();
            }
            try self.writeCloseTag("UncommittedBlocks");
            try self.nl();
        }

        try self.writeOpenTag("ResponseMetadata");
        try self.nl();
        {
            try self.writeOpenTag("RequestId");
            try self.writeText(resp.request_id);
            try self.writeCloseTag("RequestId");
            try self.nl();
            try self.writeOpenTag("Version");
            try self.writeText(resp.version);
            try self.writeCloseTag("Version");
            try self.nl();
            try self.writeOpenTag("Date");
            try self.writeText(resp.date);
            try self.writeCloseTag("Date");
            try self.nl();
        }
        try self.writeCloseTag("ResponseMetadata");
        try self.nl();

        try self.writeCloseTag("BlockList");
        try self.nl();
    }

    // ========================================================================================
    // Error responses
    // ========================================================================================

    pub const ErrorResponse = struct {
        code: []const u8,
        message: []const u8,
        request_id: []const u8 = "",
        version: []const u8 = "2024-11-04",
        date: []const u8 = "",
        details: []const struct { key: []const u8, value: []const u8 } = &.{},
    };

    pub fn writeErrorResponse(self: *Serializer, err: *const ErrorResponse, status_code: u32) !void {
        self.reset();
        try self.buf.writer().print(
            \\<?xml version="1.0" encoding="utf-8"?>
        , .{});
        try self.nl();
        try self.writeOpenTag("Error");
        try self.nl();
        {
            try self.writeOpenTag("Code");
            try self.writeText(err.code);
            try self.writeCloseTag("Code");
            try self.nl();

            try self.writeOpenTag("Message");
            try self.writeText(err.message);
            try self.writeCloseTag("Message");
            try self.nl();

            try self.writeOpenTag("Target");
            try self.writeCloseTag("Target");
            try self.nl();

            if (err.details.len > 0) {
                try self.writeOpenTag("Details");
                try self.nl();
                for (err.details) |d| {
                    try self.writeOpenTag(d.key);
                    try self.writeText(d.value);
                    try self.writeCloseTag(d.key);
                    try self.nl();
                }
                try self.writeCloseTag("Details");
                try self.nl();
            }

            try self.writeOpenTag("ResponseMetadata");
            try self.nl();
            {
                try self.writeOpenTag("RequestId");
                try self.writeText(err.request_id);
                try self.writeCloseTag("RequestId");
                try self.nl();
                try self.writeOpenTag("Version");
                try self.writeText(err.version);
                try self.writeCloseTag("Version");
                try self.nl();
                try self.writeOpenTag("Date");
                try self.writeText(err.date);
                try self.writeCloseTag("Date");
                try self.nl();
            }
            try self.writeCloseTag("ResponseMetadata");
            try self.nl();
        }
        try self.writeCloseTag("Error");
        try self.nl();

        _ = status_code;
    }

    // ========================================================================================
    // Container properties
    // ========================================================================================

    pub const ContainerPropertiesResponse = struct {
        request_id: []const u8 = "",
        version: []const u8 = "2024-11-04",
        date: []const u8 = "",
        lease_status: []const u8 = "unlocked",
        lease_state: []const u8 = "available",
        lease_duration: []const u8 = "",
        public_access: []const u8 = "",
        last_modified: []const u8 = "",
        etag: []const u8 = "",
        has_immutability_policy: bool = false,
        has_deleted: bool = false,
    };

    pub fn writeContainerPropertiesResponse(self: *Serializer, resp: *const ContainerPropertiesResponse) !void {
        self.reset();
        // Container properties are returned as HTTP headers, not XML body.
        // This method is here for completeness; in practice headers are set directly.
        _ = resp;
    }
};

test "Serializer ListContainers round-trip" {
    const allocator = testing.allocator;
    var ser = Serializer.init(allocator);
    defer ser.deinit();

    const resp = Serializer.ListContainersResponse{
        .prefix = "",
        .max_results = 5000,
        .containers = &.{
            .{
                .name = "mycontainer",
                .etag = "\"abc123\"",
                .last_modified = "Wed, 01 Jan 2025 00:00:00 GMT",
                .lease_status = "unlocked",
                .lease_state = "available",
                .public_access = "",
            },
        },
        .request_id = "test-id",
        .version = "2024-11-04",
        .date = "Wed, 01 Jan 2025 00:00:00 GMT",
    };

    try ser.writeListContainersResponse(&resp);
    const xml = ser.bytes();

    try testing.expect(mem.indexOf(u8, xml, "<Name>mycontainer</Name>") != null);
    try testing.expect(mem.indexOf(u8, xml, "<Etag>\"abc123\"</Etag>") != null);
    try testing.expect(mem.indexOf(u8, xml, "<?xml version=\"1.0\" encoding=\"utf-8\"?>") != null);
}

test "Serializer ListBlobs" {
    const allocator = testing.allocator;
    var ser = Serializer.init(allocator);
    defer ser.deinit();

    const resp = Serializer.ListBlobsResponse{
        .blobs = &.{
            .{
                .name = "myblob.txt",
                .properties = .{
                    .last_modified = "Wed, 01 Jan 2025 00:00:00 GMT",
                    .etag = "\"def456\"",
                    .content_length = 1024,
                    .content_type = "text/plain",
                    .blob_type = "BlockBlob",
                    .access_tier = "Hot",
                    .access_tier_inferred = true,
                },
                .metadata = &.{.{ .name = "Cache-Control", .value = "max-age=3600" }},
            },
        },
        .request_id = "test-id",
    };

    try ser.writeListBlobsResponse(&resp);
    const xml = ser.bytes();

    try testing.expect(mem.indexOf(u8, xml, "<Name>myblob.txt</Name>") != null);
    try testing.expect(mem.indexOf(u8, xml, "<Content-Length>1024</Content-Length>") != null);
    try testing.expect(mem.indexOf(u8, xml, "<Content-Type>text/plain</Content-Type>") != null);
}

test "Serializer GetBlockList" {
    const allocator = testing.allocator;
    var ser = Serializer.init(allocator);
    defer ser.deinit();

    const resp = Serializer.GetBlockListResponse{
        .blocks = .{
            .committed = &.{
                .{ .id = "base64blockid1", .length = 1024 },
                .{ .id = "base64blockid2", .length = 2048 },
            },
            .uncommitted = &.{},
        },
        .request_id = "test-id",
    };

    try ser.writeGetBlockListResponse(&resp);
    const xml = ser.bytes();

    try testing.expect(mem.indexOf(u8, xml, "<Name>base64blockid1</Name>") != null);
    try testing.expect(mem.indexOf(u8, xml, "<Size>1024</Size>") != null);
    try testing.expect(mem.indexOf(u8, xml, "<Size>2048</Size>") != null);
}

test "Serializer ErrorResponse" {
    const allocator = testing.allocator;
    var ser = Serializer.init(allocator);
    defer ser.deinit();

    const err = Serializer.ErrorResponse{
        .code = "ContainerNotFound",
        .message = "The specified container does not exist.",
        .request_id = "test-id",
    };

    try ser.writeErrorResponse(&err, 404);
    const xml = ser.bytes();

    try testing.expect(mem.indexOf(u8, xml, "<Code>ContainerNotFound</Code>") != null);
    try testing.expect(mem.indexOf(u8, xml, "<Message>The specified container does not exist.</Message>") != null);
}

test "XML escaping" {
    const allocator = testing.allocator;
    var ser = Serializer.init(allocator);
    defer ser.deinit();

    const resp = Serializer.ListBlobsResponse{
        .blobs = &.{
            .{
                .name = "blob<with>&\"special'chars",
                .properties = .{
                    .last_modified = "Wed, 01 Jan 2025 00:00:00 GMT",
                    .etag = "\"abc\"",
                    .content_length = 10,
                    .blob_type = "BlockBlob",
                    .access_tier = "Hot",
                    .access_tier_inferred = true,
                },
            },
        },
    };

    try ser.writeListBlobsResponse(&resp);
    const xml = ser.bytes();

    // Special chars must be escaped
    try testing.expect(mem.indexOf(u8, xml, "&lt;") != null);
    try testing.expect(mem.indexOf(u8, xml, "&gt;") != null);
    try testing.expect(mem.indexOf(u8, xml, "&amp;") != null);
}
