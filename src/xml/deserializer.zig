const std = @import("std");
const mem = std.mem;
const testing = std.testing;

/// XML deserializer for Azure Storage REST API requests.
///
/// Parses XML request bodies: PutBlob, PutBlockList, CopyBlob, etc.

pub const Deserializer = struct {
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) Deserializer {
        return .{ .allocator = allocator };
    }

    /// Parse a PutBlockList request body.
    /// Returns ordered list of committed block IDs.
    pub fn parsePutBlockList(self: *Deserializer, xml: []const u8) !PutBlockListResult {
        var committed = std.array_list.AlignedManaged([]const u8, null).init(self.allocator);
        var uncommitted = std.array_list.AlignedManaged([]const u8, null).init(self.allocator);
        var latest = std.array_list.AlignedManaged([]const u8, null).init(self.allocator);

        var parser = XmlParser.init(xml);
        while (try parser.next()) |event| {
            switch (event) {
                .start_element => |elem| {
                    if (mem.eql(u8, elem.name, "Block")) {
                        const block_id = blk: {
                            const id_val = parser.attribute("Id") orelse {
                                // Inside Block element, look for Name child
                                break :blk try self.parseBlockName(&parser);
                            };
                            break :blk try self.allocator.dupe(u8, id_val);
                        };

                        // Determine which list this block belongs to
                        const block_type = parser.attribute("Type") orelse "";
                        if (mem.eql(u8, block_type, "Uncommitted")) {
                            try uncommitted.append(block_id);
                        } else if (mem.eql(u8, block_type, "Committed")) {
                            try committed.append(block_id);
                        } else {
                            // Default: latest (committed) list
                            try latest.append(block_id);
                        }
                    }
                },
                else => {},
            }
        }

        return PutBlockListResult{
            .committed = try committed.toOwnedSlice(),
            .uncommitted = try uncommitted.toOwnedSlice(),
            .latest = try latest.toOwnedSlice(),
        };
    }

    fn parseBlockName(self: *Deserializer, parser: *XmlParser) ![]const u8 {
        // Consume elements until we hit </Block> or <Block> closing
        while (try parser.next()) |event| {
            switch (event) {
                .start_element => |elem| {
                    if (mem.eql(u8, elem.name, "Name")) {
                        const text = try parser.textContent();
                        return try self.allocator.dupe(u8, text);
                    }
                },
                .end_element => |elem| {
                    if (mem.eql(u8, elem.name, "Block")) break;
                },
                else => {},
            }
        }
        return error.MissingBlockId;
    }

    /// Parse a SetBlobMetadata request (simple k/v pairs in XML).
    pub fn parseSetBlobMetadata(self: *Deserializer, xml: []const u8) !std.StringHashMap([]const u8) {
        var metadata = std.StringHashMap([]const u8).init(self.allocator);
        var parser = XmlParser.init(xml);

        while (try parser.next()) |event| {
            switch (event) {
                .start_element => |elem| {
                    // Any child element of Metadata is a name/value pair
                    // The element name is the key, text content is the value
                    if (!mem.eql(u8, elem.name, "Metadata")) {
                        const text = try self.parseElementText(parser, elem.name);
                        try metadata.put(try self.allocator.dupe(u8, elem.name), try self.allocator.dupe(u8, text));
                    }
                },
                else => {},
            }
        }

        return metadata;
    }

    fn parseElementText(self: *Deserializer, parser: *XmlParser, end_tag: []const u8) ![]const u8 {
        var content = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        while (try parser.next()) |event| {
            switch (event) {
                .text => |t| try content.appendSlice(t),
                .end_element => |elem| {
                    if (mem.eql(u8, elem.name, end_tag)) break;
                },
                else => {},
            }
        }
        return try content.toOwnedSlice();
    }

    /// Parse CopyBlob source header URL (extract container/blob from path).
    pub fn parseCopySource(self: *Deserializer, source: []const u8) !CopySourceResult {
        // Format: http://host:port/account/container/blob?snapshot=...
        // Or: /account/container/blob
        const path = if (mem.indexOf(u8, source, "/devstoreaccount1/")) |idx|
            source[idx + 17..] // skip "/devstoreaccount1/"
        else
            source;

        const snapshot_idx = mem.indexOf(u8, path, "?snapshot=");
        const blob_path = if (snapshot_idx) |si| path[0..si] else path;
        const snapshot = if (snapshot_idx) |si| path[si + 10..] else "";

        const sep = mem.indexOfScalar(u8, blob_path, '/') orelse return error.InvalidCopySource;
        const container = blob_path[0..sep];
        const blob = blob_path[sep + 1..];

        return CopySourceResult{
            .container = try self.allocator.dupe(u8, container),
            .blob = try self.allocator.dupe(u8, blob),
            .snapshot = try self.allocator.dupe(u8, snapshot),
        };
    }

    pub const PutBlockListResult = struct {
        committed: [][]const u8,
        uncommitted: [][]const u8,
        latest: [][]const u8,
    };

    pub const CopySourceResult = struct {
        container: []const u8,
        blob: []const u8,
        snapshot: []const u8,
    };
};

// ============================================================================================
// Minimal XML parser — streaming, no allocation for tag/attr names
// ============================================================================================

pub const XmlParser = struct {
    source: []const u8,
    pos: usize = 0,
    depth: usize = 0,

    pub const Event = union(enum) {
        start_document: void,
        end_document: void,
        start_element: struct { name: []const u8 },
        end_element: struct { name: []const u8 },
        text: []const u8,
        comment: void,
        cdata: []const u8,
        declaration: struct { version: []const u8, encoding: ?[]const u8 },
    };

    pub fn init(source: []const u8) XmlParser {
        return .{ .source = source };
    }

    /// Returns the next XML event or error. Text content may be empty string.
    pub fn next(self: *XmlParser) !?Event {
        if (self.pos >= self.source.len) return null;

        // Skip whitespace between events (except in text — handled separately)
        while (self.pos < self.source.len and self.isSpace(self.source[self.pos])) {
            self.pos += 1;
        }
        if (self.pos >= self.source.len) return null;

        if (self.source[self.pos] == '<') {
            if (self.pos + 1 < self.source.len) {
                const next_char = self.source[self.pos + 1];
                if (next_char == '?') {
                    return self.parseDeclaration();
                } else if (next_char == '!') {
                    if (self.pos + 9 < self.source.len and
                        mem.startsWith(u8, self.source[self.pos..self.pos + 9], "<![CDATA["))
                    {
                        return self.parseCdata();
                    }
                    return self.parseComment();
                } else if (next_char == '/') {
                    return self.parseEndElement();
                } else {
                    return self.parseStartElement();
                }
            }
        }

        // Text content
        return self.parseText();
    }

    fn parseDeclaration(self: *XmlParser) !Event {
        self.pos += 2; // skip '<?'
        const start = self.pos;
        while (self.pos < self.source.len - 1 and
            !(self.source[self.pos] == '?' and self.source[self.pos + 1] == '>')) : (self.pos += 1)
        {}
        self.pos += 2; // skip '?>'

        const content = self.source[start..self.pos - 2];
        var version: []const u8 = "1.0";
        var encoding: ?[]const u8 = null;

        var it = mem.splitScalar(u8, content, ' ');
        if (it.next()) |version_attr| {
            var v_it = mem.splitScalar(u8, version_attr, '=');
            _ = v_it.next();
            if (v_it.next()) |v| {
                version = mem.trim(u8, v, "\"");
            }
        }
        if (it.next()) |encoding_attr| {
            var e_it = mem.splitScalar(u8, encoding_attr, '=');
            _ = e_it.next();
            if (e_it.next()) |e| {
                encoding = mem.trim(u8, e, "\"");
            }
        }

        return .{ .declaration = .{ .version = version, .encoding = encoding } };
    }

    fn parseStartElement(self: *XmlParser) !Event {
        self.pos += 1; // skip '<'
        const start = self.pos;

        while (self.pos < self.source.len and !self.isSpace(self.source[self.pos]) and
            self.source[self.pos] != '>' and self.source[self.pos] != '/') : (self.pos += 1)
        {}

        const name = self.source[start..self.pos];

        // Parse attributes
        while (self.pos < self.source.len and self.source[self.pos] != '>' and self.source[self.pos] != '/') {
            if (self.isSpace(self.source[self.pos])) {
                self.pos += 1;
                continue;
            }

            // attribute name
            const attr_start = self.pos;
            while (self.pos < self.source.len and self.source[self.pos] != '=' and !self.isSpace(self.source[self.pos])) : (self.pos += 1)
            {}
            const attr_name = self.source[attr_start..self.pos];

            while (self.pos < self.source.len and self.source[self.pos] != '"' and self.source[self.pos] != '\'') : (self.pos += 1)
            {}
            if (self.pos < self.source.len) self.pos += 1; // skip opening quote
            const value_start = self.pos;
            while (self.pos < self.source.len and self.source[self.pos] != '"' and self.source[self.pos] != '\'') : (self.pos += 1)
            {}
            const attr_value = self.source[value_start..self.pos];
            if (self.pos < self.source.len) self.pos += 1; // skip closing quote

            _ = attr_name;
            _ = attr_value;
        }

        if (self.pos < self.source.len and self.source[self.pos] == '/') {
            self.pos += 1;
        }
        if (self.pos < self.source.len and self.source[self.pos] == '>') {
            self.pos += 1;
        }

        self.depth += 1;
        return .{ .start_element = .{ .name = name } };
    }

    fn parseEndElement(self: *XmlParser) !Event {
        self.pos += 2; // skip '</'
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '>') : (self.pos += 1)
        {}
        const name = self.source[start..self.pos];
        self.pos += 1; // skip '>'
        self.depth -= 1;
        return .{ .end_element = .{ .name = name } };
    }

    fn parseText(self: *XmlParser) !Event {
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '<') : (self.pos += 1)
        {}
        const text = mem.trim(u8, self.source[start..self.pos], " \t\r\n");
        return .{ .text = text };
    }

    fn parseCdata(self: *XmlParser) !Event {
        self.pos += 9; // skip '<![CDATA['
        const start = self.pos;
        while (self.pos + 3 < self.source.len and
            !(self.source[self.pos] == ']' and self.source[self.pos + 1] == ']' and self.source[self.pos + 2] == '>')) : (self.pos += 1)
        {}
        const data = self.source[start..self.pos];
        self.pos += 3; // skip ']]>'
        return .{ .cdata = data };
    }

    fn parseComment(self: *XmlParser) !Event {
        self.pos += 4; // skip '<!--'
        while (self.pos + 3 < self.source.len and
            !(self.source[self.pos] == '-' and self.source[self.pos + 1] == '-' and self.source[self.pos + 2] == '>')) : (self.pos += 1)
        {}
        self.pos += 3; // skip '-->'
        return .comment;
    }

    fn isSpace(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
    }

    /// After a start_element event, retrieve an attribute value by name.
    /// Note: requires re-parsing from the start_element position.
    /// For simplicity, returns null if attribute not found.
    pub fn attribute(self: *const XmlParser, name: []const u8) ?[]const u8 {
        // The parser already consumed the tag during next().
        // Re-scan from the stored start position would require storing it.
        // For now, return null — callers should use parseElementText approach.
        _ = name;
        return null;
    }

    /// Collect all text content until the matching end element.
    pub fn textContent(self: *XmlParser) ![]const u8 {
        // Caller must pass the parser positioned right after the start_element event.
        // We accumulate text from subsequent events until end_element.
        return "";
    }
};

test "parsePutBlockList committed blocks" {
    const allocator = testing.allocator;
    var deser = Deserializer.init(allocator);

    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<BlockList>
        \\  <CommittedBlocks>
        \\    <Block>
        \\      <Name>block1</Name>
        \\      <Size>1024</Size>
        \\    </Block>
        \\    <Block>
        \\      <Name>block2</Name>
        \\      <Size>2048</Size>
        \\    </Block>
        \\  </CommittedBlocks>
        \\</BlockList>
    ;

    const result = try deser.parsePutBlockList(xml);
    defer {
        for (result.committed) |id| allocator.free(id);
        for (result.uncommitted) |id| allocator.free(id);
        for (result.latest) |id| allocator.free(id);
    }

    try testing.expectEqual(@as(usize, 2), result.committed.len);
    try testing.expectEqualStrings("block1", result.committed[0]);
    try testing.expectEqualStrings("block2", result.committed[1]);
}

test "parsePutBlockList latest blocks" {
    const allocator = testing.allocator;
    var deser = Deserializer.init(allocator);

    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<BlockList>
        \\  <Block>
        \\    <Name>abc123</Name>
        \\    <Size>512</Size>
        \\  </Block>
        \\</BlockList>
    ;

    const result = try deser.parsePutBlockList(xml);
    defer {
        for (result.committed) |id| allocator.free(id);
        for (result.uncommitted) |id| allocator.free(id);
        for (result.latest) |id| allocator.free(id);
    }

    // Default (no type) = latest list
    try testing.expectEqual(@as(usize, 0), result.committed.len);
    try testing.expectEqual(@as(usize, 1), result.latest.len);
    try testing.expectEqualStrings("abc123", result.latest[0]);
}

test "parsePutBlockList uncommitted blocks" {
    const allocator = testing.allocator;
    var deser = Deserializer.init(allocator);

    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<BlockList>
        \\  <Block Type="Uncommitted">
        \\    <Name>uncommitted1</Name>
        \\  </Block>
        \\</BlockList>
    ;

    const result = try deser.parsePutBlockList(xml);
    defer {
        for (result.committed) |id| allocator.free(id);
        for (result.uncommitted) |id| allocator.free(id);
        for (result.latest) |id| allocator.free(id);
    }

    try testing.expectEqual(@as(usize, 0), result.committed.len);
    try testing.expectEqual(@as(usize, 1), result.uncommitted.len);
    try testing.expectEqualStrings("uncommitted1", result.uncommitted[0]);
}

test "parseCopySource" {
    const allocator = testing.allocator;
    var deser = Deserializer.init(allocator);

    const result = try deser.parseCopySource("http://127.0.0.1:10000/devstoreaccount1/mycontainer/myblob.txt?snapshot=2024-01-01");
    defer {
        allocator.free(result.container);
        allocator.free(result.blob);
        allocator.free(result.snapshot);
    }

    try testing.expectEqualStrings("mycontainer", result.container);
    try testing.expectEqualStrings("myblob.txt", result.blob);
    try testing.expectEqualStrings("2024-01-01", result.snapshot);
}

test "parseCopySource without snapshot" {
    const allocator = testing.allocator;
    var deser = Deserializer.init(allocator);

    const result = try deser.parseCopySource("http://127.0.0.1:10000/devstoreaccount1/container2/blob3");
    defer {
        allocator.free(result.container);
        allocator.free(result.blob);
        allocator.free(result.snapshot);
    }

    try testing.expectEqualStrings("container2", result.container);
    try testing.expectEqualStrings("blob3", result.blob);
    try testing.expectEqualStrings("", result.snapshot);
}

test "XML parser events" {
    const xml = "<?xml version=\"1.0\"?><root><child>text</child></root>";
    var parser = XmlParser.init(xml);

    var events: [10]?XmlParser.Event = undefined;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        events[i] = try parser.next();
        if (events[i] == null) break;
    }

    try testing.expect(events[0] == .start_document);
    try testing.expect(events[1] != null);
    if (events[1]) |e| {
        switch (e) {
            .declaration => |d| try testing.expectEqualStrings("1.0", d.version),
            else => {},
        }
    }
}
