const std = @import("std");
const mem = std.mem;
const http = @import("../http/server.zig");
const table = @import("table.zig");

fn entityToJson(allocator: std.mem.Allocator, e: table.Entity) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        "{{\"PartitionKey\":\"{s}\",\"RowKey\":\"{s}\",\"Timestamp\":\"{s}\"}}",
        .{ e.partition_key, e.row_key, e.timestamp }
    );
}

pub const TableRouter = struct {
    allocator: std.mem.Allocator,
    store: *table.TableStore,

    pub fn init(allocator: std.mem.Allocator, store: *table.TableStore) TableRouter {
        return .{ .allocator = allocator, .store = store };
    }

    pub fn route(self: *TableRouter, method: []const u8, path: []const u8, _: []const u8, _: std.StringHashMap([]const u8), body: []const u8) !http.RouteResult {
        var segments = mem.splitScalar(u8, path, '/');
        _ = segments.next();
        _ = segments.next() orelse return .{ .status = "404", .body = "", .content_type = "" };
        const table_spec = segments.rest();
        if (table_spec.len == 0) return self.listTables();

        const paren = mem.indexOfScalar(u8, table_spec, '(');
        const table_name = if (paren) |p| table_spec[0..p] else table_spec;
        if (paren == null) {
            if (mem.eql(u8, method, "PUT")) return self.createTable(table_name);
            if (mem.eql(u8, method, "DELETE")) return self.deleteTable(table_name);
            if (mem.eql(u8, method, "GET")) return self.listEntities(table_name);
            if (mem.eql(u8, method, "POST")) return self.insertEntity(table_name, body);
        } else {
            const pk = extractKeyParam(table_spec, "PartitionKey") orelse "";
            const rk = extractKeyParam(table_spec, "RowKey") orelse "";
            if (mem.eql(u8, method, "GET")) return self.getEntity(table_name, pk, rk);
            if (mem.eql(u8, method, "PUT")) return self.updateEntity(table_name, pk, rk, body);
            if (mem.eql(u8, method, "PATCH")) return self.mergeEntity(table_name, pk, rk, body);
            if (mem.eql(u8, method, "DELETE")) return self.deleteEntity(table_name, pk, rk);
        }
        return .{ .status = "404", .body = "", .content_type = "" };
    }

    fn listTables(self: *TableRouter) !http.RouteResult {
        const tables = try self.store.listTables();
        defer self.allocator.free(tables);
        var json = try std.fmt.allocPrint(self.allocator, "{{\"value\":[]}}", .{});
        _ = &json;
        return .{ .status = "200", .body = "", .content_type = "application/json" };
    }

    fn createTable(self: *TableRouter, name: []const u8) !http.RouteResult {
        self.store.createTable(name) catch |err| {
            if (err == error.TableAlreadyExists) return .{ .status = "409", .body = "", .content_type = "" };
            return .{ .status = "500", .body = "", .content_type = "" };
        };
        return .{ .status = "201", .body = "", .content_type = "" };
    }

    fn deleteTable(self: *TableRouter, name: []const u8) !http.RouteResult {
        self.store.deleteTable(name) catch |err| {
            if (err == error.TableNotFound) return .{ .status = "404", .body = "", .content_type = "" };
            return .{ .status = "500", .body = "", .content_type = "" };
        };
        return .{ .status = "204", .body = "", .content_type = "" };
    }

    fn insertEntity(self: *TableRouter, table_name: []const u8, body: []const u8) !http.RouteResult {
        var entity = try parseEntityJson(self.allocator, body);
        defer entity.properties.deinit();
        self.store.insertEntity(table_name, entity) catch |err| {
            if (err == error.EntityAlreadyExists) return .{ .status = "409", .body = "", .content_type = "" };
            return .{ .status = "500", .body = "", .content_type = "" };
        };
        const body_out = try entityToJson(self.allocator, entity);
        return .{ .status = "201", .body = body_out, .content_type = "application/json" };
    }

    fn listEntities(self: *TableRouter, table_name: []const u8) !http.RouteResult {
        if (!self.store.tableExists(table_name)) return .{ .status = "404", .body = "", .content_type = "" };
        const entities = try self.store.listEntities(table_name);
        defer self.allocator.free(entities);
        return .{ .status = "200", .body = "", .content_type = "application/json" };
    }

    fn getEntity(self: *TableRouter, table_name: []const u8, pk: []const u8, rk: []const u8) !http.RouteResult {
        const entity = self.store.getEntity(table_name, pk, rk) catch return .{ .status = "404", .body = "", .content_type = "" };
        return .{ .status = "200", .body = try entityToJson(self.allocator, entity), .content_type = "application/json" };
    }

    fn updateEntity(self: *TableRouter, table_name: []const u8, pk: []const u8, rk: []const u8, body: []const u8) !http.RouteResult {
        var ent = try parseEntityJson(self.allocator, body);
        ent.partition_key = pk;
        ent.row_key = rk;
        self.store.insertOrReplaceEntity(table_name, ent) catch return .{ .status = "500", .body = "", .content_type = "" };
        return .{ .status = "204", .body = "", .content_type = "" };
    }

    fn mergeEntity(self: *TableRouter, table_name: []const u8, pk: []const u8, rk: []const u8, body: []const u8) !http.RouteResult {
        var ent = try parseEntityJson(self.allocator, body);
        ent.partition_key = pk;
        ent.row_key = rk;
        self.store.insertOrMergeEntity(table_name, ent) catch return .{ .status = "500", .body = "", .content_type = "" };
        return .{ .status = "204", .body = "", .content_type = "" };
    }

    fn deleteEntity(self: *TableRouter, table_name: []const u8, pk: []const u8, rk: []const u8) !http.RouteResult {
        self.store.deleteEntity(table_name, pk, rk) catch return .{ .status = "404", .body = "", .content_type = "" };
        return .{ .status = "204", .body = "", .content_type = "" };
    }
};

fn extractKeyParam(spec: []const u8, name: []const u8) ?[]const u8 {
    // Build the search pattern: name=' (but name is runtime-known)
    if (name.len == 0) return null;
    var pos: usize = 0;
    while (pos < spec.len) {
        // Look for name followed by ='
        const np = mem.indexOfScalarPos(u8, spec, pos, name[0]) orelse return null;
        if (np + name.len + 2 <= spec.len and mem.eql(u8, spec[np .. np + name.len], name) and spec[np + name.len] == '=' and spec[np + name.len + 1] == '\'') {
            const vs = np + name.len + 2;
            const end = mem.indexOfScalar(u8, spec[vs..], '\'') orelse return null;
            return spec[vs .. vs + end];
        }
        pos = np + 1;
    }
    return null;
}

fn parseEntityJson(allocator: std.mem.Allocator, body: []const u8) !table.Entity {
    var pk: []const u8 = "";
    var rk: []const u8 = "";
    var props = std.StringHashMap([]const u8).init(allocator);

    var pos: usize = 0;
    while (pos < body.len) {
        const ks = mem.indexOfScalarPos(u8, body, pos, '"') orelse break;
        const ke = mem.indexOfScalarPos(u8, body, ks + 1, '"') orelse break;
        const key = body[ks + 1 .. ke];
        pos = ke + 1;
        const colon = mem.indexOfScalarPos(u8, body, pos, ':') orelse break;
        pos = colon + 1;
        while (pos < body.len and body[pos] == ' ') pos += 1;
        if (pos < body.len and body[pos] == '"') {
            const vs = pos + 1;
            const ve = mem.indexOfScalarPos(u8, body, vs, '"') orelse break;
            const val = body[vs..ve];
            pos = ve + 1;
            if (mem.eql(u8, key, "PartitionKey")) { pk = val; } else if (mem.eql(u8, key, "RowKey")) { rk = val; } else if (!mem.eql(u8, key, "Timestamp")) { try props.put(try allocator.dupe(u8, key), try allocator.dupe(u8, val)); }
        }
    }
    if (pk.len == 0 or rk.len == 0) { props.deinit(); return error.MissingKey; }
    return table.Entity{
        .partition_key = try allocator.dupe(u8, pk),
        .row_key = try allocator.dupe(u8, rk),
        .timestamp = try allocator.dupe(u8, "now"),
        .properties = props,
    };
}