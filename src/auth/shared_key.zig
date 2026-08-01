const std = @import("std");
const crypto = std.crypto;
const mem = std.mem;

/// SharedKey authentication validator for Azure Storage.
///
/// Implements HMAC-SHA256 signature validation as described in:
/// https://learn.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key

pub const SharedKey = struct {
    /// Validates a SharedKey authorization header against expected credentials.
    ///
    /// Returns error.InvalidAuthorization on failure, or null on success.
    ///
    /// The canonicalized string format for Blob/Queue service:
    ///   VERB\n
    ///   Content-Encoding\n
    ///   Content-Language\n
    ///   Content-Length\n
    ///   Content-MD5\n
    ///   Content-Type\n
    ///   Date\n
    ///   If-Modified-Sensing\n
    ///   If-Match\n
    ///   If-None-Match\n
    ///   If-Unmodified-Sensing\n
    ///   Range\n
    ///   x-ms-date header path?comp:query\n
    ///   account name
    pub fn validate(
        allocator: mem.Allocator,
        account_name: []const u8,
        account_key: []const u8,
        expected_verb: []const u8,
        headers: *const Headers,
        path: []const u8,
        query: ?[]const u8,
    ) !void {
        // Decode the Base64 account key
        const decoded_key = try allocator.alloc(u8, 64);
        defer allocator.free(decoded_key);
        const key_len = try std.base64.standard.Decoder.decode(decoded_key, account_key);
        const key = decoded_key[0..key_len];

        // Build canonicalized string
        const canonical = try buildCanonicalString(allocator, account_name, expected_verb, headers, path, query);
        defer allocator.free(canonical);

        // Compute HMAC-SHA256
        const hmac = crypto.auth.hmacSha256;
        const signature = hmac.create(key, canonical);

        // Encode computed signature as Base64
        const sig_encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(signature.len));
        defer allocator.free(sig_encoded);
        std.base64.standard.Encoder.encode(sig_encoded, &signature);

        // Compare with provided authorization header
        const auth_sig = try extractSignatureFromAuthHeader(allocator, headers.authorization);
        defer allocator.free(auth_sig);

        if (!mem.eql(u8, sig_encoded, auth_sig)) {
            return error.InvalidAuthorization;
        }
    }

    fn extractSignatureFromAuthHeader(allocator: mem.Allocator, auth_header: []const u8) ![]u8 {
        // Format: "SharedKey <account>:<signature>"
        const prefix = "SharedKey ";
        if (!mem.startsWith(u8, auth_header, prefix)) {
            return error.InvalidAuthorizationHeaderFormat;
        }
        const rest = auth_header[prefix.len..];
        const colon_index = mem.indexOf(u8, rest, ":") orelse return error.InvalidAuthorizationHeaderFormat;
        const sig_part = rest[colon_index + 1..];
        const sig_trimmed = mem.trim(u8, sig_part, " ");
        return allocator.dupe(u8, sig_trimmed);
    }

    fn buildCanonicalString(
        allocator: mem.Allocator,
        account_name: []const u8,
        verb: []const u8,
        headers: *const Headers,
        path: []const u8,
        query: ?[]const u8,
    ) ![]u8 {
        var lines = std.ArrayList([]const u8).init(allocator);
        defer lines.deinit();

        // Each field is "field:value" or empty line for missing optional fields
        try lines.append(verb);
        try lines.append(headers.content_encoding);
        try lines.append(headers.content_language);
        try lines.append(if (headers.content_length.len > 0) headers.content_length else "");
        try lines.append(headers.content_md5);
        try lines.append(headers.content_type);
        try lines.append(headers.date);
        try lines.append(headers.if_modified_since);
        try lines.append(headers.if_match);
        try lines.append(headers.if_none_match);
        try lines.append(headers.if_unmodified_since);
        try lines.append(headers.range);

        // Canonicalized headers: x-ms- prefixed headers, sorted, no duplicates
        const canonicalized_headers = try canonicalizeMsHeaders(allocator, headers);
        defer allocator.free(canonicalized_headers);
        try lines.append(canonicalized_headers);

        // Resource path + query
        const path_and_query = try std.fmt.allocPrint(allocator, "{s}{s}", .{
            path,
            if (query) |q| try canonicalizeQueryString(allocator, q) else "",
        });
        defer allocator.free(path_and_query);
        try lines.append(path_and_query);

        // Final line: account name (for blob/queue service SharedKey)
        try lines.append(account_name);

        return mem.join(allocator, "\n", lines.items);
    }

    fn canonicalizeMsHeaders(allocator: mem.Allocator, headers: *const Headers) ![]u8 {
        var header_lines = std.ArrayList([]const u8).init(allocator);
        defer header_lines.deinit();

        const ms_headers = &[_]?[]const u8{
            headers.get("x-ms-date"),
            headers.get("x-ms-version"),
            headers.get("x-ms-blob-type"),
            headers.get("x-ms-copy-source"),
            headers.get("x-ms-blob-content-type"),
            headers.get("x-ms-blob-content-encoding"),
            headers.get("x-ms-blob-content-language"),
            headers.get("x-ms-blob-content-md5"),
            headers.get("x-ms-blob-content-disposition"),
            headers.get("x-ms-access-tier"),
            headers.get("x-ms-access-tier-change-time"),
        };

        for (ms_headers) |value| {
            if (value) |v| {
                try header_lines.append(v);
            }
        }

        return mem.join(allocator, "\n", header_lines.items);
    }

    fn canonicalizeQueryString(allocator: mem.Allocator, query: []const u8) ![]u8 {
        // Sort query parameters by name, keep empty values for comp, restype, etc.
        var params = std.StringHashMap([]const u8).init(allocator);
        defer params.deinit();

        var iter = mem.splitScalar(u8, query, '&');
        while (iter.next()) |pair| {
            const eq = mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const key = pair[0..eq];
            const value = if (eq < pair.len) pair[eq + 1..] else "";
            try params.put(key, value);
        }

        const Param = struct { name: []const u8, value: []const u8 };
        var sorted = std.ArrayList(Param).init(allocator);
        defer sorted.deinit();

        var it = params.iterator();
        while (it.next()) |entry| {
            try sorted.append(.{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        mem.sort(Param, sorted.items, {}, struct {
            fn less(_: void, a: Param, b: Param) bool {
                return mem.lessThan(u8, a.name, b.name);
            }
        }.less);

        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        for (sorted.items, 0..) |param, i| {
            if (i > 0) try result.append('&');
            try result.writer().print("{s}", .{param.name});
            if (param.value.len > 0) {
                try result.append('=');
                try result.writer().print("{s}", .{param.value});
            }
        }

        return result.toOwnedSlice();
    }
};

/// Headers needed for SharedKey authentication.
/// Required fields vary by request type; pass empty strings for unused optional headers.
pub const Headers = struct {
    authorization: []const u8,
    content_length: []const u8,
    content_type: []const u8,
    content_md5: []const u8,
    content_encoding: []const u8,
    content_language: []const u8,
    date: []const u8,
    if_modified_since: []const u8,
    if_match: []const u8,
    if_none_match: []const u8,
    if_unmodified_since: []const u8,
    range: []const u8,
    x_ms_headers: std.StringHashMap([]const u8),

    pub fn init(allocator: mem.Allocator) Headers {
        return .{
            .authorization = "",
            .content_length = "",
            .content_type = "",
            .content_md5 = "",
            .content_encoding = "",
            .content_language = "",
            .date = "",
            .if_modified_since = "",
            .if_match = "",
            .if_none_match = "",
            .if_unmodified_since = "",
            .range = "",
            .x_ms_headers = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Headers) void {
        self.x_ms_headers.deinit();
    }

    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        return self.x_ms_headers.get(name);
    }

    pub fn put(self: *Headers, name: []const u8, value: []const u8) !void {
        try self.x_ms_headers.put(name, value);
    }
};

test "SharedKey header extraction" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();

    headers.authorization = "SharedKey devstoreaccount1:Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==";

    const sig = try SharedKey.extractSignatureFromAuthHeader(allocator, headers.authorization);
    defer allocator.free(sig);

    try std.testing.expectEqualStrings("Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==", sig);
}

test "SharedKey query string canonicalization" {
    const allocator = std.testing.allocator;

    const canonical = try SharedKey.canonicalizeQueryString(allocator, "comp=list&restype=container&include=snapshots,metadata");
    defer allocator.free(canonical);

    try std.testing.expectEqualStrings("comp=list&include=snapshots,metadata&restype=container", canonical);
}
