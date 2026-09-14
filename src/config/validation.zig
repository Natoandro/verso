const std = @import("std");

pub fn isSafeText(value: []const u8) bool {
    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |char| {
        if (std.ascii.isControl(char)) return false;
    }
    return true;
}

pub fn isSafeToken(value: []const u8) bool {
    if (!isSafeText(value)) return false;
    for (value) |char| {
        if (std.ascii.isWhitespace(char)) return false;
    }
    return true;
}

pub fn isSafePath(value: []const u8) bool {
    return isSafeText(value);
}

pub fn isValidBaseUrl(value: []const u8) bool {
    const uri = std.Uri.parse(value) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "https"))
    {
        return false;
    }
    if (uri.host) |host| return !host.isEmpty();
    return false;
}

pub fn isValidServerHost(value: []const u8) bool {
    if (std.Io.net.IpAddress.parse(value, 0)) |_| return true else |_| {}
    std.Io.net.HostName.validate(value) catch return false;
    return true;
}

pub fn isLoopbackHost(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "localhost") or
        std.mem.eql(u8, value, "127.0.0.1") or
        std.mem.eql(u8, value, "::1");
}

pub fn isValidDatabaseUrl(value: []const u8) bool {
    if (!isSafePath(value)) return false;
    if (std.mem.indexOfScalar(u8, value, ':') == null) return true;

    const uri = std.Uri.parse(value) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "sqlite")) return false;
    return !uri.path.isEmpty() or uri.host != null;
}
