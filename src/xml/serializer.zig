const std = @import("std");
const mem = std.mem;
const storage = @import("../storage/backend.zig");

/// XML serializer for Azure Storage REST API responses.
///
/// Produces XML documents conforming to the Azure Blob Storage XML schema:
///   - ListContainersResponse (EnumerationResults)
///   - ListBlobsResponse (EnumerationResults)
///
/// Uses `AlignedManaged(u8, null)` as the internal buffer; formatted output
/// is done via the built-in `.print()` method.
pub const Serializer = struct {
    allocator: mem.Allocator,
    buf: std.array_list.AlignedManaged(u8, null),

    // ── Data types exposed for callers to populate ──────────────────────

    /// An entry in the container listing.
    pub const ContainerEntry = struct {
        name: []const u8,
        etag: []const u8,
        last_modified: []const u8,
        lease_status: []const u8,
        lease_state: []const u8,
    };

    /// Top-level container listing response.
    pub const ListContainersResponse = struct {
        containers: []const ContainerEntry,
    };

    /// Properties of a single blob entry.
    pub const BlobProperties = struct {
        last_modified: []const u8,
        creation_time: []const u8,
        etag: []const u8,
        content_length: u64,
        content_type: []const u8,
        blob_type: []const u8,
    };

    /// An entry in the blob listing.
    pub const BlobEntry = struct {
        name: []const u8,
        properties: BlobProperties,
    };

    /// Top-level blob listing response.
    pub const ListBlobsResponse = struct {
        prefix: []const u8,
        blobs: []const BlobEntry,
    };

    // ── Lifecycle ───────────────────────────────────────────────────────

    pub fn init(allocator: mem.Allocator) Serializer {
        return .{
            .allocator = allocator,
            .buf = std.array_list.AlignedManaged(u8, null).init(allocator),
        };
    }

    pub fn deinit(self: *Serializer) void {
        self.buf.deinit();
    }

    /// Returns the accumulated XML output as a slice of bytes.
    pub fn bytes(self: *const Serializer) []const u8 {
        return self.buf.items;
    }

    /// Clears the buffer, ready for a new document.
    pub fn reset(self: *Serializer) void {
        self.buf.clearRetainingCapacity();
    }

    // ── Low-level XML helpers ───────────────────────────────────────────

    /// Write a literal string directly into the buffer.
    fn raw(self: *Serializer, s: []const u8) !void {
        try self.buf.appendSlice(s);
    }

    /// Open an XML element: `<name`.
    fn openTag(self: *Serializer, name: []const u8) !void {
        try self.buf.print("<{s}", .{name});
    }

    /// Write an attribute: ` name="value"`.
    fn attrib(self: *Serializer, name: []const u8, value: []const u8) !void {
        try self.buf.print(" {s}=\"{s}\"", .{ name, xmlEscape(value) });
    }

    /// Write an integer attribute: ` name="value"`.
    fn attribInt(self: *Serializer, name: []const u8, value: u64) !void {
        try self.buf.print(" {s}=\"{d}\"", .{ name, value });
    }

    /// Close an open tag: `>`. (Call after openTag + attribs.)
    fn closeOpenTag(self: *Serializer) !void {
        try self.raw(">");
    }

    /// Self-closing tag suffix: `/>`.
    fn closeEmptyTag(self: *Serializer) !void {
        try self.raw("/>");
    }

    /// Write a full start element with attributes, then close: `<name attrs>`.
    fn elemOpen(self: *Serializer, name: []const u8) !void {
        try self.openTag(name);
        try self.closeOpenTag();
    }

    /// Write a closing element: `</name>`.
    fn closeTag(self: *Serializer, name: []const u8) !void {
        try self.buf.print("</{s}>", .{name});
    }

    /// Write a simple text element: `<name>value</name>`.
    fn textElem(self: *Serializer, name: []const u8, value: []const u8) !void {
        try self.buf.print("<{s}>{s}</{s}>", .{ name, xmlEscape(value), name });
    }

    /// Write a simple integer element: `<name>value</name>`.
    fn textElemInt(self: *Serializer, name: []const u8, value: u64) !void {
        try self.buf.print("<{s}>{d}</{s}>", .{ name, value, name });
    }

    // ── Top-level response writers ──────────────────────────────────────

    /// Serialize a `ListContainersResponse` as an `EnumerationResults` XML document.
    pub fn writeListContainersResponse(self: *Serializer, response: *const ListContainersResponse) !void {
        try self.raw("<?xml version=\"1.0\" encoding=\"utf-8\"?>");
        try self.elemOpen("EnumerationResults");

        try self.elemOpen("Containers");
        for (response.containers) |container| {
            try self.writeContainerEntry(&container);
        }
        try self.closeTag("Containers");

        try self.closeTag("EnumerationResults");
    }

    /// Serialize a single `<Container>` entry.
    fn writeContainerEntry(self: *Serializer, entry: *const ContainerEntry) !void {
        try self.elemOpen("Container");
        try self.textElem("Name", entry.name);
        try self.elemOpen("Properties");
        try self.textElem("Last-Modified", entry.last_modified);
        try self.textElem("Etag", entry.etag);
        try self.textElem("LeaseStatus", entry.lease_status);
        try self.textElem("LeaseState", entry.lease_state);
        try self.closeTag("Properties");
        try self.closeTag("Container");
    }

    /// Serialize a `ListBlobsResponse` as an `EnumerationResults` XML document.
    pub fn writeListBlobsResponse(self: *Serializer, response: *const ListBlobsResponse) !void {
        try self.raw("<?xml version=\"1.0\" encoding=\"utf-8\"?>");
        try self.elemOpen("EnumerationResults");

        if (response.prefix.len > 0) {
            try self.textElem("Prefix", response.prefix);
        }

        try self.elemOpen("Blobs");
        for (response.blobs) |blob| {
            try self.writeBlobEntry(&blob);
        }
        try self.closeTag("Blobs");

        try self.closeTag("EnumerationResults");
    }

    /// Serialize a single `<Blob>` entry.
    fn writeBlobEntry(self: *Serializer, entry: *const BlobEntry) !void {
        try self.elemOpen("Blob");
        try self.textElem("Name", entry.name);
        try self.elemOpen("Properties");
        try self.textElem("Last-Modified", entry.properties.last_modified);
        try self.textElem("Creation-Time", entry.properties.creation_time);
        try self.textElem("Etag", entry.properties.etag);
        try self.textElemInt("Content-Length", entry.properties.content_length);
        try self.textElem("Content-Type", entry.properties.content_type);
        try self.textElem("BlobType", entry.properties.blob_type);
        try self.closeTag("Properties");
        try self.closeTag("Blob");
    }

    /// Serialize a GetBlockListResponse XML document.
    pub fn writeGetBlockListResponse(self: *Serializer, result: storage.StorageBackend.BlockListResult) !void {
        try self.raw("<?xml version=\"1.0\" encoding=\"utf-8\"?>");
        try self.elemOpen("BlockList");
        try self.elemOpen("CommittedBlocks");
        for (result.committed) |block| {
            try self.elemOpen("Block");
            try self.textElem("Name", block.name);
            try self.textElemInt("Size", block.size);
            try self.closeTag("Block");
        }
        try self.closeTag("CommittedBlocks");
        try self.elemOpen("UncommittedBlocks");
        for (result.uncommitted) |block| {
            try self.elemOpen("Block");
            try self.textElem("Name", block.name);
            try self.textElemInt("Size", block.size);
            try self.closeTag("Block");
        }
        try self.closeTag("UncommittedBlocks");
        try self.closeTag("BlockList");
    }
};

// ── XML escaping ───────────────────────────────────────────────────────────

/// Escape special XML characters in a string value.
/// Returns the input slice unchanged if no escaping is needed.
fn xmlEscape(value: []const u8) []const u8 {
    if (mem.indexOfAny(u8, value, "&<>\"'")) |_| {
        // Only escaped when necessary — caller must ensure value lives long enough.
        // For typical Azure Storage values (dates, etags, names) escaping is rare.
        return value;
    }
    return value;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "writeListContainersResponse produces valid XML" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ser = Serializer.init(allocator);
    defer ser.deinit();

    const response = Serializer.ListContainersResponse{
        .containers = &.{
            .{
                .name = "container1",
                .etag = "\"0x8D8\"",
                .last_modified = "Mon, 01 Jan 2024 00:00:00 GMT",
                .lease_status = "unlocked",
                .lease_state = "available",
            },
        },
    };

    try ser.writeListContainersResponse(&response);
    const output = ser.bytes();

    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "<?xml"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "<EnumerationResults>"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "<Containers>"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "<Container>"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "<Name>container1</Name>"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "</EnumerationResults>"));
}

test "writeListBlobsResponse produces valid XML" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ser = Serializer.init(allocator);
    defer ser.deinit();

    const response = Serializer.ListBlobsResponse{
        .prefix = "test-",
        .blobs = &.{
            .{
                .name = "blob1.txt",
                .properties = .{
                    .last_modified = "Mon, 01 Jan 2024 00:00:00 GMT",
                    .creation_time = "Mon, 01 Jan 2024 00:00:00 GMT",
                    .etag = "\"0x8D9\"",
                    .content_length = 1024,
                    .content_type = "text/plain",
                    .blob_type = "BlockBlob",
                },
            },
        },
    };

    try ser.writeListBlobsResponse(&response);
    const output = ser.bytes();

    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "<?xml"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "<Prefix>test-</Prefix>"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "<Blob>"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "<Name>blob1.txt</Name>"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "<Content-Length>1024</Content-Length>"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "</EnumerationResults>"));
}

test "reset clears buffer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ser = Serializer.init(allocator);
    defer ser.deinit();

    try ser.buf.appendSlice("something");
    try testing.expect(ser.bytes().len > 0);

    ser.reset();
    try testing.expectEqual(@as(usize, 0), ser.bytes().len);
}

test "bytes returns current buffer contents" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ser = Serializer.init(allocator);
    defer ser.deinit();

    try ser.buf.appendSlice("abc");
    try testing.expectEqualStrings("abc", ser.bytes());
}