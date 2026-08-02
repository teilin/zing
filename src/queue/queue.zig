const std = @import("std");
const mem = std.mem;

/// In-memory queue store for Azure Storage Queue Service.
///
/// Supports messages with visibility timeout, pop receipts, and TTL semantics.
/// Auto-cleans expired messages on access.

pub const QueueStore = struct {
    allocator: mem.Allocator,
    queues: std.StringHashMap(Queue),

    pub const Queue = struct {
        name: []u8,
        metadata: std.StringHashMap([]const u8),
        messages: std.ArrayListUnmanaged(Message),
        message_counter: u64,
    };

    pub const Message = struct {
        id: []u8,
        content: []u8,
        insertion_time: i64,
        expiration_time: i64,
        pop_receipt: ?[]u8,
        dequeue_count: u64,
        next_visible_time: i64,
        time_next_visible: i64,
    };

    pub fn init(allocator: mem.Allocator) QueueStore {
        return .{
            .allocator = allocator,
            .queues = std.StringHashMap(Queue).init(allocator),
        };
    }

    pub fn deinit(self: *QueueStore) void {
        var it = self.queues.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.messages.items) |msg| {
                self.allocator.free(msg.id);
                self.allocator.free(msg.content);
            }
            entry.value_ptr.messages.deinit(self.allocator);
            self.allocator.free(entry.value_ptr.name);
        }
        self.queues.deinit();
    }

    fn now(_: *QueueStore) i64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
        return @intCast(ts.sec);
    }

    pub fn createQueue(self: *QueueStore, name: []const u8) !void {
        const gop = try self.queues.getOrPut(try self.allocator.dupe(u8, name));
        if (gop.found_existing) return;
        gop.value_ptr.* = .{
            .name = try self.allocator.dupe(u8, name),
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
            .messages = std.ArrayListUnmanaged(Message){ .items = &.{}, .capacity = 0 },
            .message_counter = 0,
        };
    }

    pub fn deleteQueue(self: *QueueStore, name: []const u8) !void {
        var entry = self.queues.fetchRemove(name) orelse return;
        for (entry.value.messages.items) |msg| {
            self.allocator.free(msg.id);
            self.allocator.free(msg.content);
        }
        entry.value.messages.deinit(self.allocator);
        self.allocator.free(entry.value.name);
    }

    pub fn queueExists(self: *QueueStore, name: []const u8) bool {
        return self.queues.contains(name);
    }

    pub fn listQueues(self: *QueueStore, _: mem.Allocator) std.StringHashMap(Queue).Iterator {
            return self.queues.iterator();
        }

    pub fn putMessage(self: *QueueStore, queue_name: []const u8, content: []const u8, visibility_timeout: u64, ttl: u64) !Message {
        const q = self.queues.getPtr(queue_name) orelse return error.QueueNotFound;
        const msg_id = try std.fmt.allocPrint(self.allocator, "{d}-{d}", .{ q.message_counter, self.now() });
        q.message_counter += 1;
        const now_sec = self.now();
        const msg = Message{
            .id = msg_id,
            .content = try self.allocator.dupe(u8, content),
            .insertion_time = now_sec,
            .expiration_time = if (ttl > 0) now_sec + @as(i64, @intCast(ttl)) else now_sec + 7 * 86400,
            .pop_receipt = null,
            .dequeue_count = 0,
            .next_visible_time = now_sec + @as(i64, @intCast(visibility_timeout)),
            .time_next_visible = now_sec,
        };
        try q.messages.append(self.allocator, msg);
        return msg;
    }

    pub fn getMessages(self: *QueueStore, queue_name: []const u8, num_messages: u64, visibility_timeout: u64) ![]Message {
        const q = self.queues.getPtr(queue_name) orelse return error.QueueNotFound;
        const now_sec = self.now();
        var result = std.ArrayListUnmanaged(Message){ .items = &.{}, .capacity = 0 };
        defer result.deinit(self.allocator);

        // Clean expired messages and collect visible ones
        var i: usize = 0;
        while (i < q.messages.items.len) {
            const msg = &q.messages.items[i];
            // Remove expired messages
            if (msg.expiration_time <= now_sec) {
                self.allocator.free(msg.id);
                self.allocator.free(msg.content);
                _ = q.messages.swapRemove(i);
                continue;
            }
            // Check if visible (next_visible_time passed)
            if (msg.next_visible_time <= now_sec and result.items.len < num_messages) {
                const pop_receipt = try std.fmt.allocPrint(self.allocator, "pr-{d}-{d}", .{ q.message_counter, now_sec });
                msg.pop_receipt = pop_receipt;
                msg.dequeue_count += 1;
                msg.next_visible_time = now_sec + @as(i64, @intCast(visibility_timeout));
                var copy = msg.*;
                copy.id = try self.allocator.dupe(u8, msg.id);
                copy.content = try self.allocator.dupe(u8, msg.content);
                try result.append(self.allocator, copy);
            }
            i += 1;
        }
        return try result.toOwnedSlice(self.allocator);
    }

    pub fn peekMessages(self: *QueueStore, queue_name: []const u8, num_messages: u64) ![]Message {
        const q = self.queues.getPtr(queue_name) orelse return error.QueueNotFound;
        const now_sec = self.now();
        var result = std.ArrayListUnmanaged(Message){ .items = &.{}, .capacity = 0 };
        defer result.deinit(self.allocator);

        for (q.messages.items) |*msg| {
            if (result.items.len >= num_messages) break;
            if (msg.expiration_time > now_sec) {
                var copy = msg.*;
                copy.id = try self.allocator.dupe(u8, msg.id);
                copy.content = try self.allocator.dupe(u8, msg.content);
                try result.append(self.allocator, copy);
            }
        }
        return try result.toOwnedSlice(self.allocator);
    }

    pub fn deleteMessage(self: *QueueStore, queue_name: []const u8, message_id: []const u8, pop_receipt: []const u8) !void {
        const q = self.queues.getPtr(queue_name) orelse return error.QueueNotFound;
        for (q.messages.items, 0..) |*msg, i| {
            if (mem.eql(u8, msg.id, message_id)) {
                if (msg.pop_receipt) |pr| {
                    if (mem.eql(u8, pr, pop_receipt)) {
                        self.allocator.free(msg.id);
                        self.allocator.free(msg.content);
                        _ = q.messages.swapRemove(i);
                        return;
                    }
                }
                return error.PopReceiptMismatch;
            }
        }
        return error.MessageNotFound;
    }

    pub fn clearMessages(self: *QueueStore, queue_name: []const u8) !void {
        const q = self.queues.getPtr(queue_name) orelse return error.QueueNotFound;
        for (q.messages.items) |msg| {
            self.allocator.free(msg.id);
            self.allocator.free(msg.content);
        }
        q.messages.clearAndFree(self.allocator);
    }

    pub fn updateMessage(self: *QueueStore, queue_name: []const u8, message_id: []const u8, pop_receipt: []const u8, visibility_timeout: u64, content: ?[]const u8) !void {
        const q = self.queues.getPtr(queue_name) orelse return error.QueueNotFound;
        for (q.messages.items) |*msg| {
            if (mem.eql(u8, msg.id, message_id)) {
                if (msg.pop_receipt) |pr| {
                    if (mem.eql(u8, pr, pop_receipt)) {
                        if (content) |c| {
                            self.allocator.free(msg.content);
                            msg.content = try self.allocator.dupe(u8, c);
                        }
                        const now_sec = self.now();
                        msg.next_visible_time = now_sec + @as(i64, @intCast(visibility_timeout));
                        return;
                    }
                }
                return error.PopReceiptMismatch;
            }
        }
        return error.MessageNotFound;
    }
};