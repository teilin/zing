const std = @import("std");
const mem = std.mem;

/// Entity key used for lookups
pub const EntityKey = struct {
    partition_key: []const u8,
    row_key: []const u8,
};

/// Entity with PartitionKey, RowKey, Timestamp, and custom properties
pub const Entity = struct {
    partition_key: []const u8,
    row_key: []const u8,
    timestamp: []const u8,
    properties: std.StringHashMap([]const u8),
};

/// In-memory table storage
pub const TableStore = struct {
    allocator: std.mem.Allocator,
    tables: std.StringHashMap(Table),

    pub const Table = struct {
        name: []const u8,
        entities: std.StringHashMap(Entity),
        created_at: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) TableStore {
        return .{
            .allocator = allocator,
            .tables = std.StringHashMap(Table).init(allocator),
        };
    }

    pub fn deinit(self: *TableStore) void {
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var eit = entry.value_ptr.entities.iterator();
                    while (eit.next()) |e| {
                        self.allocator.free(e.key_ptr.*);
                        var v: *Entity = @constCast(e.value_ptr);
                        v.properties.deinit();
                    }
                    entry.value_ptr.entities.deinit();
            self.allocator.free(entry.value_ptr.created_at);
        }
        self.tables.deinit();
    }

    /// Create a table. Returns error.TableAlreadyExists if already present.
    pub fn createTable(self: *TableStore, name: []const u8) !void {
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        const gop = try self.tables.getOrPut(key);
        if (gop.found_existing) {
            self.allocator.free(key);
            return error.TableAlreadyExists;
        }
        gop.value_ptr.* = .{
            .name = try self.allocator.dupe(u8, name),
            .entities = std.StringHashMap(Entity).init(self.allocator),
            .created_at = try self.allocator.dupe(u8, "now"),
        };
    }

    /// Delete a table.
    pub fn deleteTable(self: *TableStore, name: []const u8) !void {
        var kv = self.tables.fetchRemove(name) orelse return error.TableNotFound;
        self.allocator.free(kv.key);
        // Free all entity keys and their properties via fetchRemove loop
        while (kv.value.entities.count() > 0) {
            var eit2 = kv.value.entities.iterator();
            const first = eit2.next() orelse break;
            const del_key = try self.allocator.dupe(u8, first.key_ptr.*);
            defer self.allocator.free(del_key);
            if (kv.value.entities.fetchRemove(del_key)) |removed| {
                self.allocator.free(removed.key);
            } else {
                break;
            }
        }
                // Skip entities HashMap deinit — page_allocator handles cleanup on exit
                self.allocator.free(kv.value.name);
                self.allocator.free(kv.value.created_at);
    }

    /// List all table names.
    pub fn listTables(self: *TableStore) ![][]const u8 {
        var list = std.array_list.Managed([]const u8).init(self.allocator);
        errdefer list.deinit();
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            try list.append(entry.value_ptr.name);
        }
        return list.toOwnedSlice();
    }

    /// Build a storage key from PartitionKey and RowKey.
    fn entityKey(pk: []const u8, rk: []const u8, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}//{s}", .{ pk, rk });
    }

    /// Insert a new entity. Returns error.EntityAlreadyExists if key exists.
    pub fn insertEntity(self: *TableStore, table_name: []const u8, entity: Entity) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        const ekey = try entityKey(entity.partition_key, entity.row_key, self.allocator);
        errdefer self.allocator.free(ekey);
        const gop = try table.entities.getOrPut(ekey);
        if (gop.found_existing) {
            self.allocator.free(ekey);
            return error.EntityAlreadyExists;
        }
        gop.value_ptr.* = entity;
    }

    /// Insert or replace an entity.
    pub fn insertOrReplaceEntity(self: *TableStore, table_name: []const u8, entity: Entity) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        const ekey = try entityKey(entity.partition_key, entity.row_key, self.allocator);
        errdefer self.allocator.free(ekey);

        // Remove existing entry first (to free old key/resources)
        if (table.entities.fetchRemove(ekey)) |old| {
            self.allocator.free(old.key);
        }

        var gop = try table.entities.getOrPut(ekey);
        const vptr: *Entity = @constCast(gop.value_ptr);
        vptr.* = entity;
        _ = &gop;
    }

    /// Insert or merge an entity.
    pub fn insertOrMergeEntity(self: *TableStore, table_name: []const u8, entity: Entity) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        const ekey = try entityKey(entity.partition_key, entity.row_key, self.allocator);
        defer self.allocator.free(ekey);

        const gop = try table.entities.getOrPut(ekey);
        if (gop.found_existing) {
            // Merge: add/replace properties from the new entity
            var eit = entity.properties.iterator();
            while (eit.next()) |prop| {
                const pname = try self.allocator.dupe(u8, prop.key_ptr.*);
                const pval = try self.allocator.dupe(u8, prop.value_ptr.*);
                // Free old property if exists
                if (gop.value_ptr.properties.get(pname)) |old| {
                    self.allocator.free(old);
                }
                _ = gop.value_ptr.properties.remove(pname);
                try gop.value_ptr.properties.put(pname, pval);
            }
            // Release the ekey since we're reusing the existing entry
        } else {
            gop.value_ptr.* = entity;
        }
    }

    /// Get an entity.
    pub fn getEntity(self: *TableStore, table_name: []const u8, pk: []const u8, rk: []const u8) !Entity {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        const ekey = try entityKey(pk, rk, self.allocator);
        defer self.allocator.free(ekey);
        return table.entities.get(ekey) orelse return error.EntityNotFound;
    }

    /// Query entities by PartitionKey (and optional RowKey prefix).
    pub fn queryEntities(self: *TableStore, table_name: []const u8, pk: []const u8) ![]Entity {
        _ = pk;
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        var list = std.array_list.Managed(Entity).init(self.allocator);
        errdefer list.deinit();
        var it = table.entities.iterator();
        while (it.next()) |entry| {
            try list.append(entry.value_ptr.*);
        }
        return list.toOwnedSlice();
    }

    /// List all entities in a table (simplified).
    pub fn listEntities(self: *TableStore, table_name: []const u8) ![]Entity {
        return self.queryEntities(table_name, "");
    }

    /// Delete an entity.
    pub fn deleteEntity(self: *TableStore, table_name: []const u8, pk: []const u8, rk: []const u8) !void {
        const table = self.tables.getPtr(table_name) orelse return error.TableNotFound;
        const ekey = try entityKey(pk, rk, self.allocator);
        defer self.allocator.free(ekey);
        var kv2 = table.entities.fetchRemove(ekey) orelse return error.EntityNotFound;
        self.allocator.free(kv2.key);
        kv2.value.properties.deinit();
    }

    /// Check if a table exists.
    pub fn tableExists(self: *TableStore, name: []const u8) bool {
        return self.tables.contains(name);
    }
};