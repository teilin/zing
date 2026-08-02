const std = @import("std");
const mem = std.mem;
const xml = @import("../xml/serializer.zig");
const QueueStore = @import("queue.zig").QueueStore;

pub const QueueRouter = struct {
    allocator: mem.Allocator,
    store: *QueueStore,

    pub const RouteResult = struct {
        status: []const u8 = "200 OK",
        body: []const u8 = "",
        content_type: []const u8 = "application/xml",
    };

    pub fn init(allocator: mem.Allocator, store: *QueueStore) QueueRouter {
        return .{ .allocator = allocator, .store = store };
    }

    pub fn route(self: *QueueRouter, method: []const u8, path: []const u8, query: []const u8, _: std.StringHashMap([]const u8), body: []const u8) !RouteResult {
        // Parse path: /account[/queue[/messages[/messageid]]]
        var segments = mem.splitScalar(u8, path, '/');
        _ = segments.next(); // skip leading empty
        const account = segments.next() orelse return self.notFound();
        _ = account;

        const queue_name = segments.next() orelse {
            // Account-level: empty path (just /account)
            return self.notFound();
        };

        if (queue_name.len == 0 or queue_name[0] == '?') {
            // Account-level: /?comp=list
            if (mem.eql(u8, method, "GET")) {
                const comp = self.getQueryParam(query, "comp");
                if (comp != null and mem.eql(u8, comp.?, "list")) {
                    return self.listQueues();
                }
            }
            return self.notFound();
        }

        const sub_path = segments.rest();

        // /{queue} operations
        if (sub_path.len == 0) {
            if (mem.eql(u8, method, "PUT")) return self.createQueue(queue_name);
            if (mem.eql(u8, method, "DELETE")) return self.deleteQueue(queue_name);
            if (mem.eql(u8, method, "GET")) return self.getQueueProperties(queue_name);
            return self.notFound();
        }

        // /{queue}/messages operations
        if (mem.eql(u8, sub_path, "messages")) {
            const peek_only = self.getQueryParam(query, "peekonly");
            if (mem.eql(u8, method, "POST")) return self.putMessage(queue_name, body, query);
            if (mem.eql(u8, method, "GET") and peek_only != null and mem.eql(u8, peek_only.?, "true")) return self.peekMessages(queue_name, query);
            if (mem.eql(u8, method, "GET")) return self.getMessages(queue_name, query);
            if (mem.eql(u8, method, "DELETE")) return self.clearMessages(queue_name);
            return self.notFound();
        }

        // Parse /{queue}/messages/{messageid}
        var msg_segments = mem.splitScalar(u8, sub_path, '/');
        const msgs_seg = msg_segments.next();
        const msg_id = msg_segments.rest();

        if (msgs_seg != null and mem.eql(u8, msgs_seg.?, "messages") and msg_id.len > 0) {
            const pop_receipt = self.getQueryParam(query, "popreceipt") orelse return self.badRequest("missing popreceipt");
            if (mem.eql(u8, method, "DELETE")) return self.deleteMessage(queue_name, msg_id, pop_receipt);
            if (mem.eql(u8, method, "PUT")) return self.updateMessage(queue_name, msg_id, pop_receipt, query, body);
            return self.notFound();
        }

        return self.notFound();
    }

    // ── Queue operations ──────────────────────────────────────────────────────────

    fn listQueues(self: *QueueRouter) !RouteResult {
        var it = self.store.listQueues(self.allocator);
        var ser = xml.Serializer.init(self.allocator);
        defer ser.deinit();
        try ser.raw("<?xml version=\"1.0\" encoding=\"utf-8\"?>");
        try ser.raw("<EnumerationResults ServiceEndpoint=\"http://127.0.0.1:10001/devstoreaccount1\">");
        try ser.elemOpen("Queues");
        while (it.next()) |entry| {
            try ser.elemOpen("Queue");
            try ser.textElem("Name", entry.key_ptr.*);
            try ser.textElem("MessageCount", "0");
            try ser.closeTag("Queue");
        }
        try ser.closeTag("Queues");
        try ser.closeTag("EnumerationResults");
        const body = try self.allocator.dupe(u8, ser.bytes());
        return RouteResult{ .body = body, .content_type = "application/xml" };
    }

    fn createQueue(self: *QueueRouter, name: []const u8) !RouteResult {
        try self.store.createQueue(name);
        return RouteResult{ .status = "201 Created", .body = "", .content_type = "" };
    }

    fn deleteQueue(self: *QueueRouter, name: []const u8) !RouteResult {
        try self.store.deleteQueue(name);
        return RouteResult{ .status = "204 No Content", .body = "", .content_type = "" };
    }

    fn getQueueProperties(self: *QueueRouter, name: []const u8) !RouteResult {
        if (!self.store.queueExists(name)) return self.notFound();
        return RouteResult{ .status = "200 OK", .body = "", .content_type = "" };
    }

    fn putMessage(self: *QueueRouter, queue_name: []const u8, body: []const u8, query: []const u8) !RouteResult {
        _ = query;
        // For now return a simplified response
        // TODO: parse message body from XML/JSON
        const msg = try self.store.putMessage(queue_name, body, 0, 0);
        // Build QueueMessage XML response
        var ser = xml.Serializer.init(self.allocator);
        defer ser.deinit();
        try ser.raw("<?xml version=\"1.0\" encoding=\"utf-8\"?>");
        try ser.raw("<QueueMessagesList>");
        try ser.elemOpen("QueueMessage");
        try ser.textElem("MessageId", msg.id);
        try ser.textElem("InsertionTime", try std.fmt.allocPrint(self.allocator, "{d}", .{msg.insertion_time}));
        try ser.textElem("ExpirationTime", try std.fmt.allocPrint(self.allocator, "{d}", .{msg.expiration_time}));
        try ser.textElem("PopReceipt", msg.pop_receipt orelse "");
        try ser.textElem("TimeNextVisible", try std.fmt.allocPrint(self.allocator, "{d}", .{msg.time_next_visible}));
        try ser.closeTag("QueueMessage");
        try ser.closeTag("QueueMessagesList");
        const out = try self.allocator.dupe(u8, ser.bytes());
        return RouteResult{ .status = "201 Created", .body = out, .content_type = "application/xml" };
    }

    fn getMessages(self: *QueueRouter, queue_name: []const u8, query: []const u8) !RouteResult {
        const num = std.fmt.parseInt(u64, self.getQueryParam(query, "numofmessages") orelse "1", 10) catch 1;
        const vis_timeout = std.fmt.parseInt(u64, self.getQueryParam(query, "visibilitytimeout") orelse "30", 10) catch 30;
        const messages = try self.store.getMessages(queue_name, num, vis_timeout);
        defer {
            for (messages) |m| {
                self.allocator.free(m.id);
                self.allocator.free(m.content);
            }
            self.allocator.free(messages);
        }
        var ser = xml.Serializer.init(self.allocator);
        defer ser.deinit();
        try ser.raw("<?xml version=\"1.0\" encoding=\"utf-8\"?>");
        try ser.raw("<QueueMessagesList>");
        for (messages) |msg| {
            try ser.elemOpen("QueueMessage");
            try ser.textElem("MessageId", msg.id);
            try ser.textElem("InsertionTime", try std.fmt.allocPrint(self.allocator, "{d}", .{msg.insertion_time}));
            try ser.textElem("ExpirationTime", try std.fmt.allocPrint(self.allocator, "{d}", .{msg.expiration_time}));
            try ser.textElem("PopReceipt", msg.pop_receipt orelse "");
            try ser.textElem("TimeNextVisible", try std.fmt.allocPrint(self.allocator, "{d}", .{msg.time_next_visible}));
            try ser.textElem("MessageText", msg.content);
            try ser.textElem("DequeueCount", try std.fmt.allocPrint(self.allocator, "{d}", .{msg.dequeue_count}));
            try ser.closeTag("QueueMessage");
        }
        try ser.closeTag("QueueMessagesList");
        const out = try self.allocator.dupe(u8, ser.bytes());
        return RouteResult{ .body = out, .content_type = "application/xml" };
    }

    fn peekMessages(self: *QueueRouter, queue_name: []const u8, query: []const u8) !RouteResult {
        const num = std.fmt.parseInt(u64, self.getQueryParam(query, "numofmessages") orelse "1", 10) catch 1;
        const messages = try self.store.peekMessages(queue_name, num);
        defer {
            for (messages) |m| {
                self.allocator.free(m.id);
                self.allocator.free(m.content);
            }
            self.allocator.free(messages);
        }
        var ser = xml.Serializer.init(self.allocator);
        defer ser.deinit();
        try ser.raw("<?xml version=\"1.0\" encoding=\"utf-8\"?>");
        try ser.raw("<QueueMessagesList>");
        for (messages) |msg| {
            try ser.elemOpen("QueueMessage");
            try ser.textElem("MessageId", msg.id);
            try ser.textElem("InsertionTime", try std.fmt.allocPrint(self.allocator, "{d}", .{msg.insertion_time}));
            try ser.textElem("ExpirationTime", try std.fmt.allocPrint(self.allocator, "{d}", .{msg.expiration_time}));
            try ser.textElem("DequeueCount", try std.fmt.allocPrint(self.allocator, "{d}", .{msg.dequeue_count}));
            try ser.textElem("MessageText", msg.content);
            try ser.closeTag("QueueMessage");
        }
        try ser.closeTag("QueueMessagesList");
        const out = try self.allocator.dupe(u8, ser.bytes());
        return RouteResult{ .body = out, .content_type = "application/xml" };
    }

    fn deleteMessage(self: *QueueRouter, queue_name: []const u8, msg_id: []const u8, pop_receipt: []const u8) !RouteResult {
        try self.store.deleteMessage(queue_name, msg_id, pop_receipt);
        return RouteResult{ .status = "204 No Content", .body = "", .content_type = "" };
    }

    fn clearMessages(self: *QueueRouter, queue_name: []const u8) !RouteResult {
        try self.store.clearMessages(queue_name);
        return RouteResult{ .status = "204 No Content", .body = "", .content_type = "" };
    }

    fn updateMessage(self: *QueueRouter, queue_name: []const u8, msg_id: []const u8, pop_receipt: []const u8, query: []const u8, body: []const u8) !RouteResult {
        const vis_timeout = std.fmt.parseInt(u64, self.getQueryParam(query, "visibilitytimeout") orelse "30", 10) catch 30;
        try self.store.updateMessage(queue_name, msg_id, pop_receipt, vis_timeout, if (body.len > 0) body else null);
        return RouteResult{ .status = "204 No Content", .body = "", .content_type = "" };
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────

    fn getQueryParam(_: *QueueRouter, query: []const u8, name: []const u8) ?[]const u8 {
        if (query.len == 0) return null;
        var it = mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const val = pair[eq + 1..];
            if (mem.eql(u8, key, name)) return val;
        }
        return null;
    }

    fn notFound(_: *QueueRouter) RouteResult {
        return RouteResult{ .status = "404 Not Found", .body = "Not Found", .content_type = "text/plain" };
    }

    fn badRequest(_: *QueueRouter, msg: []const u8) RouteResult {
        return RouteResult{ .status = "400 Bad Request", .body = msg, .content_type = "text/plain" };
    }
};