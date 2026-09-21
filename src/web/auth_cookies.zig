const std = @import("std");
const auth_crypto = @import("../auth/crypto.zig");
const context = @import("context.zig");

pub fn formatCookie(buffer: []u8, name: []const u8, cookie_value: []const u8, http_only: bool) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{s}={s}; Path=/; Secure; {s}SameSite=Lax",
        .{ name, cookie_value, if (http_only) "HttpOnly; " else "" },
    );
}

pub fn value(request: *const context.RequestContext, name: []const u8) ?[]const u8 {
    const header = request.cachedHeaderValue("cookie") orelse return null;
    var cookies = std.mem.splitScalar(u8, header, ';');
    while (cookies.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const separator = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (!std.mem.eql(u8, trimmed[0..separator], name)) continue;
        return parseValue(trimmed[separator + 1 ..]);
    }
    return null;
}

fn parseValue(value_text: []const u8) ?[]const u8 {
    if (value_text.len != auth_crypto.encoded_secret_length) return null;
    for (value_text) |character| if (!std.ascii.isHex(character)) return null;
    return value_text;
}

test "cookie values reject malformed session credentials" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseValue("bad"));
    try std.testing.expectEqual(@as(?[]const u8, null), parseValue("0123"));
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        parseValue("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef").?,
    );
}

test "session and csrf cookie attributes are explicit" {
    var buffer: [192]u8 = undefined;
    const cookie = try formatCookie(&buffer, "__Host-verso_session", "token", true);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "Secure") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "SameSite=Lax") != null);
}
