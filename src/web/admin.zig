const std = @import("std");
const auth = @import("auth.zig");
const context = @import("context.zig");
const layer = @import("layer.zig");
const router = @import("router.zig");

pub const ProtectedEditorHandler = struct {
    guard: *auth.SessionGuard,
    router: *router.Router,
    fallback: layer.Layer,

    pub fn handle(self: *@This(), request: *context.RequestContext, _: layer.Next) anyerror!void {
        var layers = [_]layer.Layer{
            .init(self.router),
            self.fallback,
        };
        return self.guard.handle(request, .{ .layers = &layers, .index = 0 });
    }
};

pub fn originFromBaseUrl(base_url: []const u8) ![]const u8 {
    const scheme_end = std.mem.indexOf(u8, base_url, "://") orelse return error.InvalidBaseUrl;
    const authority_start = scheme_end + 3;
    if (authority_start >= base_url.len) return error.InvalidBaseUrl;
    const authority_end = std.mem.indexOfAnyPos(u8, base_url, authority_start, "/?#") orelse base_url.len;
    if (authority_end == authority_start) return error.InvalidBaseUrl;
    return base_url[0..authority_end];
}

pub fn parseTrustedProxyAddresses(
    configured: []const u8,
    storage: *[16][]const u8,
) ![]const []const u8 {
    var count: usize = 0;
    var addresses = std.mem.splitScalar(u8, configured, ',');
    while (addresses.next()) |address| {
        if (address.len == 0) continue;
        if (count == storage.len) return error.TooManyTrustedProxies;
        storage[count] = address;
        count += 1;
    }
    return storage[0..count];
}
