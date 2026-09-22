const std = @import("std");

pub const CookiePolicy = struct {
    pub fn init() CookiePolicy {
        return .{};
    }

    pub fn name(_: CookiePolicy) []const u8 {
        return "__Host-verso_session";
    }

    pub fn path(_: CookiePolicy) []const u8 {
        return "/";
    }

    pub fn isSecure(_: CookiePolicy) bool {
        return true;
    }

    pub fn isHttpOnly(_: CookiePolicy) bool {
        return true;
    }

    pub fn sameSiteText(_: CookiePolicy) []const u8 {
        return "Lax";
    }
};

pub const Request = struct {
    method: std.http.Method,
    scheme: []const u8,
    host: []const u8,
    remote_address: []const u8,
    origin: ?[]const u8 = null,
    forwarded_scheme: ?[]const u8 = null,
    forwarded_host: ?[]const u8 = null,
};

pub const OriginPolicy = struct {
    public_origin: []const u8,
    allowed_origins: []const []const u8 = &.{},
    trusted_proxy_addresses: []const []const u8 = &.{},

    pub fn check(self: OriginPolicy, request: Request, allocator: std.mem.Allocator) !void {
        const has_forwarded_scheme = request.forwarded_scheme != null;
        const has_forwarded_host = request.forwarded_host != null;
        if (has_forwarded_scheme != has_forwarded_host) return error.IncompleteForwardedOrigin;

        const forwarded = has_forwarded_scheme and has_forwarded_host;
        if (forwarded and !self.isTrustedProxy(request.remote_address)) {
            return error.UntrustedForwardedOrigin;
        }

        const effective_origin = if (forwarded)
            try formatOrigin(allocator, request.forwarded_scheme.?, request.forwarded_host.?)
        else
            try formatOrigin(allocator, request.scheme, request.host);
        defer allocator.free(effective_origin);
        if (!(try originsEqual(allocator, effective_origin, self.public_origin))) {
            return error.InvalidPublicOrigin;
        }

        if (isUnsafeMethod(request.method)) {
            const request_origin = request.origin orelse return error.MissingOrigin;
            if (!(try self.originAllowed(allocator, request_origin))) return error.OriginNotAllowed;
        }
    }

    fn isTrustedProxy(self: OriginPolicy, remote_address: []const u8) bool {
        for (self.trusted_proxy_addresses) |trusted| {
            if (std.mem.eql(u8, trusted, remote_address)) return true;
            if (remote_address.len > 2 and remote_address[0] == '[' and
                remote_address[remote_address.len - 1] == ']' and
                std.mem.eql(u8, trusted, remote_address[1 .. remote_address.len - 1]))
            {
                return true;
            }
        }
        return false;
    }

    pub fn trustedProxy(self: OriginPolicy, remote_address: []const u8) bool {
        return self.isTrustedProxy(remote_address);
    }

    fn originAllowed(self: OriginPolicy, allocator: std.mem.Allocator, origin: []const u8) !bool {
        if (!isValidOrigin(origin)) return false;
        if (try originsEqual(allocator, origin, self.public_origin)) return true;
        for (self.allowed_origins) |allowed| {
            if (try originsEqual(allocator, origin, allowed)) return true;
        }
        return false;
    }
};

pub fn isUnsafeMethod(method: std.http.Method) bool {
    return switch (method) {
        .GET, .HEAD, .OPTIONS => false,
        else => true,
    };
}

fn formatOrigin(allocator: std.mem.Allocator, scheme: []const u8, host: []const u8) ![]u8 {
    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) {
        return error.InvalidForwardedScheme;
    }
    if (!isValidHost(host)) return error.InvalidForwardedHost;
    return std.fmt.allocPrint(allocator, "{s}://{s}", .{ scheme, host });
}

fn isValidOrigin(origin: []const u8) bool {
    if (origin.len < 8 or std.mem.eql(u8, origin, "null")) return false;
    const separator = std.mem.indexOf(u8, origin, "://") orelse return false;
    if (separator != 4 and separator != 5) return false;
    return isValidHost(origin[separator + 3 ..]) and
        (std.mem.eql(u8, origin[0..separator], "http") or
            std.mem.eql(u8, origin[0..separator], "https"));
}

fn originsEqual(allocator: std.mem.Allocator, left: []const u8, right: []const u8) !bool {
    const canonical_left = try canonicalOrigin(allocator, left);
    defer allocator.free(canonical_left);
    const canonical_right = try canonicalOrigin(allocator, right);
    defer allocator.free(canonical_right);
    return std.mem.eql(u8, canonical_left, canonical_right);
}

fn canonicalOrigin(allocator: std.mem.Allocator, origin: []const u8) ![]u8 {
    const separator = std.mem.indexOf(u8, origin, "://") orelse return error.InvalidOrigin;
    const scheme = origin[0..separator];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and
        !std.ascii.eqlIgnoreCase(scheme, "https")) return error.InvalidOrigin;

    const authority_start = separator + 3;
    if (authority_start >= origin.len) return error.InvalidOrigin;
    const authority_end = std.mem.indexOfAnyPos(u8, origin, authority_start, "/?#") orelse origin.len;
    if (authority_end != origin.len) return error.InvalidOrigin;
    var authority = origin[authority_start..authority_end];
    if (!isValidHost(authority)) return error.InvalidOrigin;

    const default_port = if (std.ascii.eqlIgnoreCase(scheme, "http")) ":80" else ":443";
    if (std.mem.endsWith(u8, authority, default_port)) {
        authority = authority[0 .. authority.len - default_port.len];
        if (authority.len == 0) return error.InvalidOrigin;
    }

    const buffer = try allocator.alloc(u8, scheme.len + 3 + authority.len);
    errdefer allocator.free(buffer);
    for (scheme, 0..) |character, index| buffer[index] = std.ascii.toLower(character);
    @memcpy(buffer[scheme.len .. scheme.len + 3], "://");
    for (authority, 0..) |character, index| {
        buffer[scheme.len + 3 + index] = std.ascii.toLower(character);
    }
    return buffer;
}

fn isValidHost(host: []const u8) bool {
    if (host.len == 0) return false;
    for (host) |character| {
        if (character <= 0x20 or character == 0x7f or
            character == '/' or character == '?' or character == '#' or
            character == '@' or character == '\\' or character == ',') return false;
    }
    return true;
}

test "unsafe requests require same-origin or explicitly allowed origin" {
    const policy = OriginPolicy{ .public_origin = "https://example.test" };
    try policy.check(.{
        .method = .GET,
        .scheme = "https",
        .host = "example.test",
        .remote_address = "192.0.2.1",
    }, std.testing.allocator);
    try std.testing.expectError(error.MissingOrigin, policy.check(.{
        .method = .POST,
        .scheme = "https",
        .host = "example.test",
        .remote_address = "192.0.2.1",
    }, std.testing.allocator));
    try std.testing.expectError(error.OriginNotAllowed, policy.check(.{
        .method = .POST,
        .scheme = "https",
        .host = "example.test",
        .remote_address = "192.0.2.1",
        .origin = "https://evil.test",
    }, std.testing.allocator));
    try policy.check(.{
        .method = .POST,
        .scheme = "https",
        .host = "example.test",
        .remote_address = "192.0.2.1",
        .origin = "https://example.test",
    }, std.testing.allocator);
}

test "forwarded origin headers are accepted only from configured proxies" {
    const policy = OriginPolicy{
        .public_origin = "https://example.test",
        .trusted_proxy_addresses = &.{"192.0.2.10"},
    };
    try policy.check(.{
        .method = .GET,
        .scheme = "http",
        .host = "internal:8080",
        .remote_address = "192.0.2.10",
        .forwarded_scheme = "https",
        .forwarded_host = "example.test",
    }, std.testing.allocator);
    try std.testing.expectError(error.UntrustedForwardedOrigin, policy.check(.{
        .method = .GET,
        .scheme = "https",
        .host = "example.test",
        .remote_address = "192.0.2.11",
        .forwarded_scheme = "https",
        .forwarded_host = "example.test",
    }, std.testing.allocator));
}

test "trusted forwarded unsafe requests still require an allowed origin" {
    const policy = OriginPolicy{
        .public_origin = "https://example.test",
        .trusted_proxy_addresses = &.{"192.0.2.10"},
    };
    try std.testing.expectError(error.OriginNotAllowed, policy.check(.{
        .method = .POST,
        .scheme = "http",
        .host = "internal:8080",
        .remote_address = "192.0.2.10",
        .origin = "https://evil.test",
        .forwarded_scheme = "https",
        .forwarded_host = "example.test",
    }, std.testing.allocator));
    try policy.check(.{
        .method = .POST,
        .scheme = "http",
        .host = "internal:8080",
        .remote_address = "192.0.2.10",
        .origin = "https://example.test",
        .forwarded_scheme = "https",
        .forwarded_host = "example.test",
    }, std.testing.allocator);
}

test "origin comparison canonicalizes scheme case and default ports" {
    const policy = OriginPolicy{
        .public_origin = "HTTPS://Example.test:443",
    };
    try policy.check(.{
        .method = .POST,
        .scheme = "https",
        .host = "example.test",
        .remote_address = "192.0.2.1",
        .origin = "https://EXAMPLE.TEST",
    }, std.testing.allocator);
}

test "origin comparison allocates for long authorities" {
    const host = ("a" ** 1100) ++ ".example.test";
    const origin = "https://" ++ host;
    const policy = OriginPolicy{ .public_origin = origin };
    try policy.check(.{
        .method = .GET,
        .scheme = "https",
        .host = host,
        .remote_address = "192.0.2.1",
    }, std.testing.allocator);
}

test "session cookie policy is host-only and protected" {
    const policy = CookiePolicy.init();
    try std.testing.expectEqualStrings("__Host-verso_session", policy.name());
    try std.testing.expect(policy.isSecure());
    try std.testing.expect(policy.isHttpOnly());
    try std.testing.expectEqualStrings("/", policy.path());
    try std.testing.expectEqualStrings("Lax", policy.sameSiteText());
}
