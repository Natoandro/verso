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

const max_route_captures = 16;
const route_capture_storage_size = 16 * 1024;
const max_cached_headers = 16;
const cached_header_storage_size = 16 * 1024;
const request_target_storage_size = 8 * 1024;

const CachedHeader = struct {
    name_start: usize,
    name_len: usize,
    value_start: usize,
    value_len: usize,
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
    route_capture_entries: [max_route_captures]RouteCapture = undefined,
    route_capture_count: usize = 0,
    route_capture_storage: []u8,
    route_capture_storage_used: usize = 0,
    request_target_storage: []u8,
    request_target_len: usize = 0,
    cached_headers: []CachedHeader,
    cached_header_count: usize = 0,
    cached_header_storage: []u8,
    cached_header_storage_used: usize = 0,

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
        const route_capture_storage = try request_allocator.alloc(u8, route_capture_storage_size);
        const request_target_storage = try request_allocator.alloc(u8, request_target_storage_size);
        const cached_headers = try request_allocator.alloc(CachedHeader, max_cached_headers);
        const cached_header_storage = try request_allocator.alloc(u8, cached_header_storage_size);
        const owned_remote_address = try request_allocator.dupe(u8, remote_address);

        var result: RequestContext = .{
            .server = server,
            .arena = arena,
            .stream = stream,
            .request = request,
            .started_at = started_at,
            .remote_address = owned_remote_address,
            .route_capture_storage = route_capture_storage,
            .request_target_storage = request_target_storage,
            .cached_headers = cached_headers,
            .cached_header_storage = cached_header_storage,
        };
        result.cacheRequestMetadata();
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
        return self.request_target_storage[0..self.request_target_len];
    }

    pub fn cachedHeaderValue(self: *const RequestContext, name: []const u8) ?[]const u8 {
        var result: ?[]const u8 = null;
        for (self.cached_headers[0..self.cached_header_count]) |header| {
            const header_name = self.cached_header_storage[header.name_start .. header.name_start + header.name_len];
            if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;
            if (result != null) return null;
            result = std.mem.trim(u8, self.cached_header_storage[header.value_start .. header.value_start + header.value_len], " \t");
        }
        return result;
    }

    fn cacheRequestMetadata(self: *RequestContext) void {
        const target_len = @min(self.request.head.target.len, self.request_target_storage.len);
        @memcpy(self.request_target_storage[0..target_len], self.request.head.target[0..target_len]);
        self.request_target_len = target_len;

        var headers = self.request.iterateHeaders();
        while (headers.next()) |header| {
            if (!shouldCacheHeader(header.name)) continue;
            if (self.cached_header_count == max_cached_headers) continue;
            const required = header.name.len + header.value.len;
            if (self.cached_header_storage_used + required > self.cached_header_storage.len) continue;

            const name_start = self.cached_header_storage_used;
            @memcpy(self.cached_header_storage[name_start .. name_start + header.name.len], header.name);
            const value_start = name_start + header.name.len;
            @memcpy(self.cached_header_storage[value_start .. value_start + header.value.len], header.value);
            self.cached_header_storage_used += required;
            self.cached_headers[self.cached_header_count] = .{
                .name_start = name_start,
                .name_len = header.name.len,
                .value_start = value_start,
                .value_len = header.value.len,
            };
            self.cached_header_count += 1;
        }
    }

    pub fn routeParam(self: *const RequestContext, name: []const u8) ?[]const u8 {
        for (self.route_capture_entries[0..self.route_capture_count]) |capture| {
            if (std.mem.eql(u8, capture.name, name)) return capture.value;
        }
        return null;
    }

    pub fn clearRouteCaptures(self: *RequestContext) void {
        self.route_capture_count = 0;
        self.route_capture_storage_used = 0;
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
