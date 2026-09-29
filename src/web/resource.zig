const std = @import("std");
const router = @import("router.zig");
const static_content = @import("static.zig");

pub const EmbeddedStatic = static_content.EmbeddedStatic;

pub const ResourceVersion = enum { none, content_hash };
pub const ResourceCache = enum { no_store, revalidate, immutable };

pub const StaticResourceOptions = struct {
    content_type: ?[]const u8 = null,
    cache: ?ResourceCache = null,
    version: ResourceVersion = .none,
};

pub const StaticResource = struct {
    pattern: []const u8,
    content: []const u8,
    content_type: []const u8,
    cache_control: []const u8,
    etag: []const u8,
    href_value: []const u8,

    pub fn init(
        comptime pattern: []const u8,
        comptime embedded_content: []const u8,
        comptime options: StaticResourceOptions,
    ) StaticResource {
        @setEvalBranchQuota(100_000);
        const path = comptime validateResourcePattern(pattern);
        const content_type = options.content_type orelse (comptime inferContentType(path) orelse
            @compileError(std.fmt.comptimePrint("static resource route '{s}' needs an explicit content type", .{pattern})));
        const hash = comptime std.hash.Wyhash.hash(0, embedded_content);
        const hash_text = comptime std.fmt.comptimePrint("{x}", .{hash});
        const etag = comptime std.fmt.comptimePrint("\"{s}\"", .{hash_text});
        const cache = options.cache orelse switch (options.version) {
            .none => .no_store,
            .content_hash => .immutable,
        };
        if (cache == .immutable and options.version != .content_hash) {
            @compileError(std.fmt.comptimePrint("immutable static resource '{s}' requires content-hash versioning", .{pattern}));
        }
        const href_value = comptime switch (options.version) {
            .none => path,
            .content_hash => std.fmt.comptimePrint("{s}?v={s}", .{ path, hash_text }),
        };
        const policy = comptime static_content.ResponsePolicy{
            .status = .ok,
            .cache_control = cacheControl(cache),
            .etag = etag,
        };
        return .{
            .pattern = pattern,
            .content = embedded_content,
            .content_type = content_type,
            .cache_control = policy.cache_control,
            .etag = etag,
            .href_value = href_value,
        };
    }

    pub fn route(comptime self: @This()) router.Route {
        const policy = comptime static_content.ResponsePolicy{
            .status = .ok,
            .cache_control = self.cache_control,
            .etag = self.etag,
        };
        return router.compile(self.pattern, EmbeddedStatic.handler(self.content, self.content_type, policy));
    }

    pub fn href(comptime self: @This()) []const u8 {
        return self.href_value;
    }
};

fn validateResourcePattern(comptime pattern: []const u8) []const u8 {
    if (pattern.len < 4 or pattern[0] != 'G' or pattern[1] != 'E' or pattern[2] != 'T' or pattern[3] != ' ') {
        @compileError(std.fmt.comptimePrint("static resource route '{s}' must use GET", .{pattern}));
    }
    const path = pattern[4..];
    if (path.len == 0 or path[0] != '/') {
        @compileError(std.fmt.comptimePrint("static resource route '{s}' must be a literal path", .{pattern}));
    }
    for (path) |character| {
        if (character == '{' or character == '}' or character == '%' or character == '\\' or
            character == '?' or character == '#')
        {
            @compileError(std.fmt.comptimePrint("static resource route '{s}' must be a literal path", .{pattern}));
        }
    }
    return path;
}

fn inferContentType(path: []const u8) ?[]const u8 {
    const content_type = static_content.contentTypeForPath(path);
    return if (std.mem.eql(u8, content_type, "application/octet-stream")) @as(?[]const u8, null) else content_type;
}

fn cacheControl(cache: ResourceCache) []const u8 {
    return switch (cache) {
        .no_store => "no-store",
        .revalidate => "public, max-age=0, must-revalidate",
        .immutable => "public, max-age=31536000, immutable",
    };
}

test "static resources infer metadata and generate content-hashed links" {
    const resource = comptime StaticResource.init("GET /site.css", "body {}", .{ .version = .content_hash });
    const table = router.routes(.{resource.route()});

    try std.testing.expectEqual(std.http.Method.GET, resource.route().method);
    try std.testing.expectEqual(@as(?usize, 0), router.resolve(table.asSlice(), .GET, "/site.css"));
    try std.testing.expectEqual(@as(?usize, 0), router.resolve(table.asSlice(), .HEAD, "/site.css"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", resource.content_type);
    try std.testing.expectEqualStrings("public, max-age=31536000, immutable", resource.cache_control);
    try std.testing.expect(std.mem.startsWith(u8, resource.href(), "/site.css?v="));
    try std.testing.expectEqualStrings("body {}", resource.content);
    try std.testing.expect(resource.etag.len > 2);
}

test "static resource defaults preserve no-store for unversioned content" {
    const resource = comptime StaticResource.init("GET /download.bin", "bytes", .{
        .content_type = "application/octet-stream",
    });

    try std.testing.expectEqualStrings("/download.bin", resource.href());
    try std.testing.expectEqualStrings("no-store", resource.cache_control);
    try std.testing.expectEqualStrings("application/octet-stream", resource.content_type);
}

test "content-hash links change when embedded content changes" {
    const original = comptime StaticResource.init("GET /site.css", "body {}", .{ .version = .content_hash });
    const changed = comptime StaticResource.init("GET /site.css", "body { color: red; }", .{ .version = .content_hash });

    try std.testing.expect(!std.mem.eql(u8, original.href(), changed.href()));
    try std.testing.expect(!std.mem.eql(u8, original.etag, changed.etag));
}
