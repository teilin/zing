const std = @import("std");
const mem = std.mem;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// Azure Storage Service SAS (Shared Access Signature) token validator.
///
/// SAS tokens are passed as query parameters and grant delegated access
/// to specific resources for a limited time window.
///
/// Spec: https://learn.microsoft.com/en-us/rest/api/storageservices/create-service-sas
///
/// Supported SAS token query parameters:
///   sp  - Signed permissions (r=read, w=write, d=delete, l=list, a=add, c=create)
///   st  - Signed start time (ISO 8601)
///   se  - Signed expiry time (ISO 8601)
///   sv  - Signed version (API version, e.g. "2024-11-04")
///   sr  - Signed resource (b=blob, c=container)
///   si  - Signed identifier (stored access policy name)
///   sip - Signed IP (IP range, e.g. "0.0.0.0-255.255.255.255")
///   spr - Signed protocol (https, http)
///   sig - Signature (HMAC-SHA256, Base64 encoded)
///   rscc - Response cache-control override
///   rscd - Response content-disposition override
///   rsce - Response content-encoding override
///   rscl - Response content-language override
///   rsct - Response content-type override

pub const Sastor = struct {
    // SAS token fields
    permissions: ?[]const u8 = null,
    start_time: ?[]const u8 = null,
    expiry_time: ?[]const u8 = null,
    version: ?[]const u8 = null,
    resource: ?[]const u8 = null,
    identifier: ?[]const u8 = null,
    ip_range: ?[]const u8 = null,
    protocol: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    cache_control: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
    content_language: ?[]const u8 = null,
    content_type: ?[]const u8 = null,

    allocator: mem.Allocator,

    /// Parse a SAS token from query string parameters.
    /// Pass the full query string (e.g. "sv=2024-11-04&se=...&sig=...").
    /// The `sig` parameter is the HMAC-SHA256 signature.
    pub fn parse(allocator: mem.Allocator, query: []const u8) !Sastor {
        var sas = Sastor{
            .allocator = allocator,
        };

        var it = mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const val = try allocator.dupe(u8, pair[eq + 1 ..]);

            if (mem.eql(u8, key, "sp")) sas.permissions = val
            else if (mem.eql(u8, key, "st")) sas.start_time = val
            else if (mem.eql(u8, key, "se")) sas.expiry_time = val
            else if (mem.eql(u8, key, "sv")) sas.version = val
            else if (mem.eql(u8, key, "sr")) sas.resource = val
            else if (mem.eql(u8, key, "si")) sas.identifier = val
            else if (mem.eql(u8, key, "sip")) sas.ip_range = val
            else if (mem.eql(u8, key, "spr")) sas.protocol = val
            else if (mem.eql(u8, key, "sig")) sas.signature = val
            else if (mem.eql(u8, key, "rscc")) sas.cache_control = val
            else if (mem.eql(u8, key, "rscd")) sas.content_disposition = val
            else if (mem.eql(u8, key, "rsce")) sas.content_encoding = val
            else if (mem.eql(u8, key, "rscl")) sas.content_language = val
            else if (mem.eql(u8, key, "rsct")) sas.content_type = val;
        }

        return sas;
    }

    pub fn deinit(self: *Sastor) void {
        inline for (comptime std.meta.fieldNames(@TypeOf(self.*))) |field_name| {
            const field = @field(self.*, field_name);
            if (!mem.eql(u8, field_name, "allocator") and @TypeOf(field) == ?[]const u8) {
                if (field) |val| self.allocator.free(val);
            }
        }
    }

    /// Validate the SAS token for a given request.
    /// Returns error.InvalidAuthorization on failure.
    pub fn validate(
        self: *const Sastor,
        account_name: []const u8,
        account_key: []const u8,
        method: []const u8,
        path: []const u8,
        query: []const u8,
    ) !void {
        // 1. Check expiry
        if (self.expiry_time) |expiry| {
            if (!isExpired(expiry)) {} else return error.SasTokenExpired;
        } else return error.MissingSasExpiry;

        // 2. Check permissions against method
        if (self.permissions) |perms| {
            if (!checkPermissions(perms, method, self.resource)) {
                return error.SasPermissionDenied;
            }
        } else return error.MissingSasPermissions;

        // 3. Validate signature
        if (self.signature) |sig| {
            const canonical = try buildStringToSign(
                self.allocator,
                self,
                account_name,
                method,
                path,
                query,
            );
            defer self.allocator.free(canonical);

            // Decode account key
            const decoded_key = try self.allocator.alloc(u8, 64);
            defer self.allocator.free(decoded_key);
            _ = try std.base64.standard.Decoder.decode(decoded_key, account_key);
            const key = decoded_key[0..@min(decoded_key.len, account_key.len / 4 * 3)];

            // Compute HMAC-SHA256
            var mac: [HmacSha256.mac_length]u8 = undefined;
            HmacSha256.create(&mac, canonical, key);

            // Encode as Base64
            const sig_encoded = try self.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(mac.len));
            defer self.allocator.free(sig_encoded);
            _ = std.base64.standard.Encoder.encode(sig_encoded, &mac);

            if (!mem.eql(u8, sig_encoded, sig)) {
                return error.InvalidSignature;
            }
        } else return error.MissingSasSignature;
    }

    fn buildStringToSign(
        allocator: mem.Allocator,
        sas: *const Sastor,
        account_name: []const u8,
        method: []const u8,
        path: []const u8,
        query: []const u8,
    ) ![]u8 {
        _ = query;
        _ = method;

        // Canonicalized resource: /blob/account/container/blob
        const canonical_name = try std.fmt.allocPrint(allocator, "/blob/{s}{s}", .{ account_name, path });
        defer allocator.free(canonical_name);

        var lines = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer lines.deinit();

        try lines.append(sas.permissions orelse "");
        try lines.append(sas.start_time orelse "");
        try lines.append(sas.expiry_time orelse "");
        try lines.append(canonical_name);
        try lines.append(sas.identifier orelse "");
        try lines.append(sas.ip_range orelse "");
        try lines.append(sas.protocol orelse "");
        try lines.append(sas.version orelse "");
        try lines.append(sas.resource orelse "");
        try lines.append(""); // snapshot time (not supported)
        try lines.append(sas.cache_control orelse "");
        try lines.append(sas.content_disposition orelse "");
        try lines.append(sas.content_encoding orelse "");
        try lines.append(sas.content_language orelse "");
        try lines.append(sas.content_type orelse "");

        return mem.join(allocator, "\n", lines.items);
    }
};

/// Check if the expiry time is still valid.
/// Expiry is ISO 8601 format: "2026-01-01T00:00:00Z"
fn isExpired(expiry: []const u8) bool {
    _ = expiry;
    // For MVP, always return false (not expired).
    // TODO: implement proper ISO 8601 parsing and comparison
    return false;
}

/// Check if the SAS permissions allow the requested operation.
/// Permissions are single-character strings: "r", "w", "d", "l", "a", "c"
fn checkPermissions(permissions: []const u8, method: []const u8, resource: ?[]const u8) bool {
    _ = resource;

    for (permissions) |perm| {
        switch (perm) {
            'r' => {
                // Read: GET, HEAD
                if (mem.eql(u8, method, "GET") or mem.eql(u8, method, "HEAD"))
                    return true;
            },
            'w' => {
                // Write: PUT (upload)
                if (mem.eql(u8, method, "PUT"))
                    return true;
            },
            'd' => {
                // Delete: DELETE
                if (mem.eql(u8, method, "DELETE"))
                    return true;
            },
            'l' => {
                // List: GET with comp=list
                if (mem.eql(u8, method, "GET"))
                    return true;
            },
            'c' => {
                // Create: PUT (container)
                if (mem.eql(u8, method, "PUT"))
                    return true;
            },
            else => {},
        }
    }
    return false;
}

test "SAS token parsing" {
    const allocator = std.testing.allocator;
    const query = "sv=2024-11-04&se=2026-01-01T00:00:00Z&sr=b&sp=r&sig=abc123";

    var sas = try Sastor.parse(allocator, query);
    defer sas.deinit();

    try std.testing.expectEqualStrings("2024-11-04", sas.version.?);
    try std.testing.expectEqualStrings("2026-01-01T00:00:00Z", sas.expiry_time.?);
    try std.testing.expectEqualStrings("b", sas.resource.?);
    try std.testing.expectEqualStrings("r", sas.permissions.?);
    try std.testing.expectEqualStrings("abc123", sas.signature.?);
}

test "permission check: read blob" {
    try std.testing.expect(checkPermissions("r", "GET", null));
    try std.testing.expect(!checkPermissions("r", "DELETE", null));
    try std.testing.expect(!checkPermissions("w", "GET", null));
    try std.testing.expect(checkPermissions("w", "PUT", null));
    try std.testing.expect(checkPermissions("d", "DELETE", null));
    try std.testing.expect(checkPermissions("l", "GET", null));
    try std.testing.expect(checkPermissions("rwdl", "DELETE", null));
    try std.testing.expect(checkPermissions("rwdl", "GET", null));
    try std.testing.expect(checkPermissions("rwdl", "PUT", null));
}

test "string-to-sign construction" {
    const allocator = std.testing.allocator;
    const query = "sv=2024-11-04&se=2026-01-01T00:00:00Z&sr=b&sp=r&sig=xyz";
    var sas = try Sastor.parse(allocator, query);
    defer sas.deinit();

    const s2s = try Sastor.buildStringToSign(
        allocator, &sas, "devstoreaccount1", "GET", "/mycontainer/myblob.txt", "",
    );
    defer allocator.free(s2s);

    // Verify structure
    try std.testing.expect(s2s.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, s2s, "/blob/devstoreaccount1/mycontainer/myblob.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, s2s, "2026-01-01T00:00:00Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, s2s, "2024-11-04") != null);
}