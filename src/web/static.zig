const std = @import("std");
const builtin = @import("builtin");
const context = @import("context.zig");
const errors = @import("errors.zig");
const layer = @import("layer.zig");
const web_logging = @import("logging.zig");

pub const RequestContext = context.RequestContext;
pub const Next = layer.Next;
pub const Layer = layer.Layer;
pub const Error = anyerror;

pub const max_file_bytes: usize = 8 * 1024 * 1024;

pub const ResponsePolicy = struct {
    status: std.http.Status = .ok,
    cache_control: []const u8 = "no-store",
    etag: ?[]const u8 = null,
};

pub const EmbeddedStatic = struct {
    content: []const u8,
    content_type: []const u8,
    policy: ResponsePolicy,

    pub fn init(content: []const u8, content_type: []const u8, policy: ResponsePolicy) EmbeddedStatic {
        return .{
            .content = content,
            .content_type = content_type,
            .policy = policy,
        };
    }

    /// Creates a stateless handler for comptime-embedded route declarations.
    pub fn handler(
        comptime content: []const u8,
        comptime content_type: []const u8,
        comptime policy: ResponsePolicy,
    ) Layer {
        return Layer.initFn(comptimeHandler(content, content_type, policy));
    }

    pub fn layer(self: *@This()) Layer {
        return Layer.init(self);
    }

    pub fn handle(self: *@This(), request: *RequestContext, _: Next) Error!void {
        return respond(request, self.content, self.content_type, self.policy);
    }
};

fn comptimeHandler(
    comptime content: []const u8,
    comptime content_type: []const u8,
    comptime policy: ResponsePolicy,
) *const fn (*RequestContext, Next) Error!void {
    return struct {
        fn handle(request: *RequestContext, _: Next) Error!void {
            return respond(request, content, content_type, policy);
        }
    }.handle;
}

pub const FilesystemStaticOptions = struct {
    path_parameter: []const u8 = "path",
    policy: ResponsePolicy = .{},
    max_bytes: usize = max_file_bytes,
    generate_etag: bool = true,
};

pub const FilesystemStatic = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    path_parameter: []const u8,
    policy: ResponsePolicy,
    max_bytes: usize,
    generate_etag: bool,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        root: std.Io.Dir,
        options: FilesystemStaticOptions,
    ) FilesystemStatic {
        return .{
            .io = io,
            .allocator = allocator,
            .root = root,
            .path_parameter = options.path_parameter,
            .policy = options.policy,
            .max_bytes = options.max_bytes,
            .generate_etag = options.generate_etag,
        };
    }

    /// Opens an explicit public root without following a symlink at its root.
    pub fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        root_path: []const u8,
        options: FilesystemStaticOptions,
    ) !FilesystemStatic {
        const root = if (std.fs.path.isAbsolute(root_path))
            try std.Io.Dir.openDirAbsolute(io, root_path, .{ .access_sub_paths = true, .follow_symlinks = false })
        else
            try std.Io.Dir.cwd().openDir(io, root_path, .{ .access_sub_paths = true, .follow_symlinks = false });
        return init(io, allocator, root, options);
    }

    pub fn deinit(self: *FilesystemStatic) void {
        self.root.close(self.io);
    }

    pub fn layer(self: *@This()) Layer {
        return Layer.init(self);
    }

    pub fn handle(self: *@This(), request: *RequestContext, _: Next) Error!void {
        const relative_path = request.routeParam(self.path_parameter) orelse {
            web_logging.logDiagnostic(request, "info", "static.request_rejected", "static path parameter was missing", .not_found, null, "missing static path");
            return respondStatus(request, .not_found);
        };
        if (!isSafeRelativePath(relative_path)) {
            web_logging.logDiagnostic(request, "warn", "static.request_rejected", "static path was rejected", .not_found, error.InvalidPath, "unsafe static path");
            return respondStatus(request, .not_found);
        }

        const content = self.readFileWithAllocator(request.allocator(), relative_path) catch |read_error| switch (read_error) {
            error.StreamTooLong => {
                web_logging.logDiagnostic(request, "warn", "static.request_rejected", "static file exceeded configured size", .payload_too_large, read_error, "static file too large");
                return respondStatus(request, .payload_too_large);
            },
            error.Canceled => return error.Canceled,
            error.OutOfMemory => {
                web_logging.logDiagnostic(request, "error", "static.read_failed", "static file allocation failed", .internal_server_error, read_error, null);
                return error.OutOfMemory;
            },
            else => {
                web_logging.logDiagnostic(request, "error", "static.read_failed", "static file could not be read", .not_found, read_error, null);
                return respondStatus(request, .not_found);
            },
        };
        defer request.allocator().free(content);

        const etag_buffer = request.allocator().alloc(u8, 24) catch |failure| {
            web_logging.logDiagnostic(request, "error", "static.response_failed", "could not allocate static response metadata", .internal_server_error, failure, null);
            return failure;
        };
        const etag = if (self.generate_etag)
            std.fmt.bufPrint(etag_buffer, "\"{x}\"", .{std.hash.Wyhash.hash(0, content)}) catch unreachable
        else
            null;
        var policy = self.policy;
        policy.etag = etag;
        return respond(request, content, contentTypeForPath(relative_path), policy);
    }

    fn readFile(self: *FilesystemStatic, relative_path: []const u8) ![]u8 {
        return self.readFileWithAllocator(self.allocator, relative_path);
    }

    fn readFileWithAllocator(self: *FilesystemStatic, allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
        if (!isSafeRelativePath(relative_path)) return error.InvalidPath;
        var file = try self.root.openFile(self.io, relative_path, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        });
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        if (stat.kind != .file) return error.NotAFile;

        var reader = file.reader(self.io, &.{});
        return reader.interface.allocRemaining(allocator, .limited(self.max_bytes + 1));
    }
};

pub fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[path.len - 1] == '/') return false;
    if (std.fs.path.isAbsolute(path)) return false;

    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            return false;
        }
        for (segment) |character| {
            if (character == '\\' or character == 0 or character < 0x20 or character == 0x7f or
                character == '%' or character == '?' or character == '#' or character == ':')
            {
                return false;
            }
        }
    }
    return true;
}

pub fn contentTypeForPath(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".html") or std.ascii.eqlIgnoreCase(extension, ".htm")) {
        return "text/html; charset=utf-8";
    }
    if (std.ascii.eqlIgnoreCase(extension, ".css")) return "text/css; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".js") or std.ascii.eqlIgnoreCase(extension, ".mjs")) {
        return "text/javascript; charset=utf-8";
    }
    if (std.ascii.eqlIgnoreCase(extension, ".json")) return "application/json";
    if (std.ascii.eqlIgnoreCase(extension, ".svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(extension, ".xml")) return "application/xml";
    if (std.ascii.eqlIgnoreCase(extension, ".txt")) return "text/plain; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".wasm")) return "application/wasm";
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) {
        return "image/jpeg";
    }
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(extension, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(extension, ".avif")) return "image/avif";
    if (std.ascii.eqlIgnoreCase(extension, ".ico")) return "image/x-icon";
    if (std.ascii.eqlIgnoreCase(extension, ".woff")) return "font/woff";
    if (std.ascii.eqlIgnoreCase(extension, ".woff2")) return "font/woff2";
    if (std.ascii.eqlIgnoreCase(extension, ".ttf")) return "font/ttf";
    if (std.ascii.eqlIgnoreCase(extension, ".otf")) return "font/otf";
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) return "application/pdf";
    return "application/octet-stream";
}

fn respondStatus(request: *RequestContext, status: std.http.Status) Error!void {
    return errors.respond(request, status);
}

fn respond(
    request: *RequestContext,
    content: []const u8,
    content_type: []const u8,
    policy: ResponsePolicy,
) Error!void {
    var headers: [3]std.http.Header = undefined;
    var header_count: usize = 0;
    headers[header_count] = .{ .name = "content-type", .value = content_type };
    header_count += 1;
    if (policy.cache_control.len > 0) {
        headers[header_count] = .{ .name = "cache-control", .value = policy.cache_control };
        header_count += 1;
    }
    if (policy.etag) |etag| {
        headers[header_count] = .{ .name = "etag", .value = etag };
        header_count += 1;
    }

    const not_modified = policy.status == .ok and policy.etag != null and
        matchesIfNoneMatch(request.request.head_buffer, policy.etag.?);
    const status: std.http.Status = if (not_modified) .not_modified else policy.status;
    const body: []const u8 = if (not_modified) &.{} else content;
    request.request.respond(body, .{
        .status = status,
        .keep_alive = true,
        .extra_headers = headers[0..header_count],
    }) catch |response_error| {
        if (response_error == error.Canceled) return error.Canceled;
        web_logging.logDiagnostic(request, "error", "http.response_failed", "failed to write static response", status, response_error, null);
        return response_error;
    };
    request.response_status = @intFromEnum(status);
}

fn matchesIfNoneMatch(head_buffer: []const u8, etag: []const u8) bool {
    var lines = std.mem.splitSequence(u8, head_buffer, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..separator], "if-none-match")) continue;
        var values = std.mem.splitScalar(u8, std.mem.trim(u8, line[separator + 1 ..], " \t"), ',');
        while (values.next()) |value| {
            if (std.mem.eql(u8, std.mem.trim(u8, value, " \t"), "*") or
                std.mem.eql(u8, std.mem.trim(u8, value, " \t"), etag))
            {
                return true;
            }
        }
    }
    return false;
}

test "static paths reject traversal and encoded or platform separators" {
    try std.testing.expect(isSafeRelativePath("assets/editor.js"));
    try std.testing.expect(!isSafeRelativePath("../secrets"));
    try std.testing.expect(!isSafeRelativePath("assets/../secrets"));
    try std.testing.expect(!isSafeRelativePath("/etc/passwd"));
    try std.testing.expect(!isSafeRelativePath("assets\\editor.js"));
    try std.testing.expect(!isSafeRelativePath("assets/%2fpasswd"));
    try std.testing.expect(!isSafeRelativePath("assets//editor.js"));
}

test "static content types are selected by extension without sniffing" {
    try std.testing.expectEqualStrings("text/css; charset=utf-8", contentTypeForPath("site.CSS"));
    try std.testing.expectEqualStrings("application/wasm", contentTypeForPath("module.wasm"));
    try std.testing.expectEqualStrings("application/octet-stream", contentTypeForPath("unknown.data"));
}

test "filesystem static reads only regular files below its opened root" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    try temporary_directory.dir.createDirPath(std.testing.io, "public");
    var public_dir = try temporary_directory.dir.openDir(std.testing.io, "public", .{});
    var file = try public_dir.createFile(std.testing.io, "index.txt", .{});
    try file.writeStreamingAll(std.testing.io, "public content");
    file.close(std.testing.io);

    var static_handler = FilesystemStatic.init(std.testing.io, std.testing.allocator, public_dir, .{});
    defer static_handler.deinit();
    const body = try static_handler.readFile("index.txt");
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("public content", body);
    try std.testing.expectError(error.InvalidPath, static_handler.readFile("../index.txt"));

    if (builtin.os.tag != .windows) {
        var outside_file = try temporary_directory.dir.createFile(std.testing.io, "outside.txt", .{});
        try outside_file.writeStreamingAll(std.testing.io, "private content");
        outside_file.close(std.testing.io);
        try public_dir.symLink(std.testing.io, "../outside.txt", "outside-link.txt", .{});

        const symlink_result = static_handler.readFile("outside-link.txt");
        if (symlink_result) |symlink_body| {
            std.testing.allocator.free(symlink_body);
            return error.SymlinkWasServed;
        } else |_| {}
    }
}

test "if-none-match accepts a matching ETag without accepting a different tag" {
    const head = "GET /site.css HTTP/1.1\r\nIf-None-Match: \"abc\", \"def\"\r\n\r\n";
    try std.testing.expect(matchesIfNoneMatch(head, "\"def\""));
    try std.testing.expect(!matchesIfNoneMatch(head, "\"xyz\""));
}
