const std = @import("std");

pub fn isSafeText(text: []const u8) bool {
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |char| {
        if (std.ascii.isControl(char)) return false;
    }
    return true;
}

pub fn isSafeToken(token: []const u8) bool {
    if (!isSafeText(token)) return false;
    for (token) |char| {
        if (std.ascii.isWhitespace(char)) return false;
    }
    return true;
}

pub fn isValidPath(path: []const u8) bool {
    if (!isSafeText(path)) return false;

    var components = std.fs.path.componentIterator(path);
    while (components.next()) |component| {
        if (std.mem.eql(u8, component.name, "..")) return false;
    }
    return true;
}

pub fn isValidBaseUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "https"))
    {
        return false;
    }
    if (uri.host) |host| return !host.isEmpty();
    return false;
}

pub fn isValidServerHost(host: []const u8) bool {
    if (std.Io.net.IpAddress.parse(host, 0)) |_| return true else |_| {}
    std.Io.net.HostName.validate(host) catch return false;
    return true;
}

pub fn isLoopbackHost(host: []const u8) bool {
    if (std.Io.net.IpAddress.parse(host, 0)) |address| {
        return switch (address) {
            .ip4 => |ip4| ip4.bytes[0] == 127,
            .ip6 => |ip6| std.mem.eql(u8, &ip6.bytes, &.{
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 1,
            }),
        };
    } else |_| {}

    return std.ascii.eqlIgnoreCase(host, "localhost");
}

pub fn isLoopbackBaseUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buffer) catch return false;
    return isLoopbackHost(host.bytes);
}

pub fn isValidDatabaseUrl(database_url: []const u8) bool {
    if (!isSafeText(database_url)) return false;
    if (std.mem.indexOfScalar(u8, database_url, ':') == null) return isValidPath(database_url);

    const uri = std.Uri.parse(database_url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "sqlite")) return false;
    if (uri.path.isEmpty() and uri.host == null) return false;

    var path_buffer: [1024]u8 = undefined;
    const database_path = uri.path.toRaw(&path_buffer) catch return false;
    return isValidPath(database_path);
}

test "path validation rejects traversal while allowing configured roots" {
    try std.testing.expect(isValidPath("./data/assets"));
    try std.testing.expect(isValidPath("/var/lib/verso"));
    try std.testing.expect(!isValidPath("./data/../secrets"));
    try std.testing.expect(!isValidPath(""));
}

test "database validation accepts SQLite paths and URLs only" {
    try std.testing.expect(isValidDatabaseUrl("./data/verso.db"));
    try std.testing.expect(isValidDatabaseUrl("sqlite:///./data/verso.db"));
    try std.testing.expect(!isValidDatabaseUrl("postgres://localhost/verso"));
}

test "loopback validation covers the complete IPv4 loopback range" {
    try std.testing.expect(isLoopbackHost("127.0.0.1"));
    try std.testing.expect(isLoopbackHost("127.0.0.2"));
    try std.testing.expect(isLoopbackHost("::1"));
    try std.testing.expect(!isLoopbackHost("128.0.0.1"));
}
