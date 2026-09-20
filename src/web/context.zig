const std = @import("std");
const application_identity = @import("../application/identity.zig");
const application_documents = @import("../application/documents.zig");
const identity_management = @import("../application/identity_management.zig");
const auth_security = @import("../auth/security.zig");
const config = @import("../config.zig");
const logging = @import("../logging.zig");

pub const ServerContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *const config.Config,
    logger: *logging.Logger,
    identity_service: *application_identity.Service,
    document_service: *application_documents.Service,
    identity_management_service: *identity_management.Service,
    origin_policy: auth_security.OriginPolicy,
};

pub const RouteCapture = struct {
    name: []const u8,
    value: []const u8,
};

const CachedHeader = struct {
    name: []const u8,
    value: []const u8,
};

const RouteCaptureNames = std.ArrayList([]const u8);
const RouteCaptureEntries = std.ArrayList(RouteCapture);

const RouteCaptureFrame = struct {
    names: RouteCaptureNames,
    captures: RouteCaptureEntries,
};

const RouteCaptureStack = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayList(RouteCaptureFrame),

    fn init(allocator: std.mem.Allocator) RouteCaptureStack {
        return .{
            .allocator = allocator,
            .frames = .empty,
        };
    }

    fn push(self: *RouteCaptureStack, names: []const []const u8) !void {
        for (names, 0..) |name, index| {
            for (names[0..index]) |previous_name| {
                if (std.mem.eql(u8, previous_name, name)) return error.RouteCaptureNameConflict;
            }
            if (self.contains(name)) return error.RouteCaptureNameConflict;
        }

        var frame = RouteCaptureFrame{
            .names = .empty,
            .captures = .empty,
        };
        try frame.names.appendSlice(self.allocator, names);
        try self.frames.append(self.allocator, frame);
    }

    fn pop(self: *RouteCaptureStack) void {
        _ = self.frames.pop();
    }

    fn add(self: *RouteCaptureStack, name: []const u8, capture_value: []const u8) !void {
        if (self.frames.items.len == 0) return error.RouteCaptureFrameMissing;
        const frame = &self.frames.items[self.frames.items.len - 1];
        try frame.captures.append(self.allocator, .{
            .name = name,
            .value = try self.allocator.dupe(u8, capture_value),
        });
    }

    fn value(self: *const RouteCaptureStack, name: []const u8) ?[]const u8 {
        var frame_index = self.frames.items.len;
        while (frame_index > 0) : (frame_index -= 1) {
            const captures = self.frames.items[frame_index - 1].captures.items;
            var capture_index = captures.len;
            while (capture_index > 0) : (capture_index -= 1) {
                const capture = captures[capture_index - 1];
                if (std.mem.eql(u8, capture.name, name)) return capture.value;
            }
        }
        return null;
    }

    fn contains(self: *const RouteCaptureStack, name: []const u8) bool {
        for (self.frames.items) |frame| {
            for (frame.names.items) |capture_name| {
                if (std.mem.eql(u8, capture_name, name)) return true;
            }
        }
        return false;
    }
};

const CachedHeaders = struct {
    allocator: std.mem.Allocator,
    headers: std.ArrayList(CachedHeader),
    captured_names: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) CachedHeaders {
        return .{
            .allocator = allocator,
            .headers = .empty,
            .captured_names = .empty,
        };
    }

    fn capture(
        self: *CachedHeaders,
        request: *std.http.Server.Request,
        names: []const []const u8,
    ) !void {
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (!self.isUncapturedName(names, header.name)) continue;
            try self.headers.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, header.name),
                .value = try self.allocator.dupe(u8, header.value),
            });
        }

        for (names, 0..) |name, index| {
            if (containsHeaderName(names[0..index], name)) continue;
            if (self.isCaptured(name)) continue;
            try self.captured_names.append(self.allocator, try self.allocator.dupe(u8, name));
        }
    }

    fn isUncapturedName(self: *const CachedHeaders, names: []const []const u8, name: []const u8) bool {
        for (names) |requested_name| {
            if (self.isCaptured(requested_name)) continue;
            if (std.ascii.eqlIgnoreCase(requested_name, name)) return true;
        }
        return false;
    }

    fn isCaptured(self: *const CachedHeaders, name: []const u8) bool {
        return containsHeaderName(self.captured_names.items, name);
    }

    fn value(self: *const CachedHeaders, name: []const u8) ?[]const u8 {
        var result: ?[]const u8 = null;
        for (self.headers.items) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
            if (result != null) return null;
            result = std.mem.trim(u8, header.value, " \t");
        }
        return result;
    }
};

pub const RequestContext = struct {
    server: *ServerContext,
    arena: std.heap.ArenaAllocator,
    stream: *const std.Io.net.Stream,
    request: *std.http.Server.Request,
    started_at: std.Io.Timestamp,
    remote_address: []const u8 = "",
    response_status: ?u16 = null,
    authenticated_user_id: ?i64 = null,
    route_captures: RouteCaptureStack,
    request_target: []const u8 = "",
    cached_headers: CachedHeaders,

    pub fn init(
        server: *ServerContext,
        stream: *const std.Io.net.Stream,
        request: *std.http.Server.Request,
        started_at: std.Io.Timestamp,
        remote_address: []const u8,
    ) !RequestContext {
        var arena = std.heap.ArenaAllocator.init(server.allocator);
        errdefer arena.deinit();
        const request_allocator = arena.allocator();
        const owned_remote_address = try request_allocator.dupe(u8, remote_address);
        const owned_target = try request_allocator.dupe(u8, request.head.target);

        const result: RequestContext = .{
            .server = server,
            .arena = arena,
            .stream = stream,
            .request = request,
            .started_at = started_at,
            .remote_address = owned_remote_address,
            .route_captures = RouteCaptureStack.init(request_allocator),
            .request_target = owned_target,
            .cached_headers = CachedHeaders.init(request_allocator),
        };
        return result;
    }

    pub fn deinit(self: *RequestContext) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Returns the allocator for data whose lifetime is bounded by this
    /// request. The arena is released when `deinit` runs after the pipeline.
    pub fn allocator(self: *RequestContext) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn requestTarget(self: *const RequestContext) []const u8 {
        return self.request_target;
    }

    pub fn cachedHeaderValue(self: *const RequestContext, name: []const u8) ?[]const u8 {
        return self.cached_headers.value(name);
    }

    pub fn cacheHeaders(self: *RequestContext, names: []const []const u8) !void {
        try self.cached_headers.capture(self.request, names);
    }

    pub fn routeParam(self: *const RequestContext, name: []const u8) ?[]const u8 {
        return self.route_captures.value(name);
    }

    pub fn addRouteCapture(self: *RequestContext, name: []const u8, value: []const u8) !void {
        return self.route_captures.add(name, value);
    }

    pub fn pushRouteCaptureFrame(self: *RequestContext, names: []const []const u8) !void {
        return self.route_captures.push(names);
    }

    pub fn popRouteCaptureFrame(self: *RequestContext) void {
        self.route_captures.pop();
    }
};

fn containsHeaderName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, name)) return true;
    }
    return false;
}

pub const Context = RequestContext;

test "cached headers follow the requested allowlist and are idempotent" {
    const request_bytes =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "X-Trace-Id: abc123\r\n" ++
        "Cookie: ignored=1\r\n\r\n";

    var server: std.http.Server = .{
        .reader = .{
            .in = undefined,
            .state = .received_head,
            .interface = undefined,
            .max_head_len = 4096,
        },
        .out = undefined,
    };
    var request: std.http.Server.Request = .{
        .server = &server,
        .head = undefined,
        .head_buffer = @constCast(request_bytes),
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cached = CachedHeaders.init(arena.allocator());

    try cached.capture(&request, &.{ "HOST", "x-trace-id" });
    try cached.capture(&request, &.{ "host", "X-TRACE-ID" });

    try std.testing.expectEqualStrings("example.test", cached.value("host").?);
    try std.testing.expectEqualStrings("abc123", cached.value("x-trace-id").?);
    try std.testing.expect(cached.value("cookie") == null);
    try std.testing.expectEqual(@as(usize, 2), cached.headers.items.len);
    try std.testing.expectEqual(@as(usize, 2), cached.captured_names.items.len);
}

test "cached headers reject ambiguous repeated fields" {
    const request_bytes =
        "GET / HTTP/1.1\r\n" ++
        "X-Trace-Id: first\r\n" ++
        "x-trace-id: second\r\n\r\n";

    var server: std.http.Server = .{
        .reader = .{
            .in = undefined,
            .state = .received_head,
            .interface = undefined,
            .max_head_len = 4096,
        },
        .out = undefined,
    };
    var request: std.http.Server.Request = .{
        .server = &server,
        .head = undefined,
        .head_buffer = @constCast(request_bytes),
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cached = CachedHeaders.init(arena.allocator());

    try cached.capture(&request, &.{"x-trace-id"});

    try std.testing.expect(cached.value("X-Trace-Id") == null);
    try std.testing.expectEqual(@as(usize, 2), cached.headers.items.len);
}
