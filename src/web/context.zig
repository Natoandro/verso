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

    fn init(allocator: std.mem.Allocator) CachedHeaders {
        return .{
            .allocator = allocator,
            .headers = .empty,
        };
    }

    fn capture(self: *CachedHeaders, request: *std.http.Server.Request) !void {
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (!shouldCacheHeader(header.name)) continue;
            try self.headers.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, header.name),
                .value = try self.allocator.dupe(u8, header.value),
            });
        }
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

        var result: RequestContext = .{
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
        try result.cacheRequestMetadata();
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

    fn cacheRequestMetadata(self: *RequestContext) !void {
        try self.cached_headers.capture(self.request);
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

fn shouldCacheHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "host") or
        std.ascii.eqlIgnoreCase(name, "origin") or
        std.ascii.eqlIgnoreCase(name, "cookie") or
        std.ascii.eqlIgnoreCase(name, "x-csrf-token") or
        std.ascii.eqlIgnoreCase(name, "hx-request") or
        std.ascii.eqlIgnoreCase(name, "x-forwarded-proto") or
        std.ascii.eqlIgnoreCase(name, "x-forwarded-host");
}

pub const Context = RequestContext;
