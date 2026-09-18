const std = @import("std");
const application_identity = @import("../application/identity.zig");
const auth_security = @import("../auth/security.zig");
const config = @import("../config.zig");
const logging = @import("../logging.zig");

pub const ServerContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *const config.Config,
    logger: *logging.Logger,
    identity_service: *application_identity.Service,
    origin_policy: auth_security.OriginPolicy,
};

pub const RouteCapture = struct {
    name: []const u8,
    value: []const u8,
};

const max_route_captures = 16;
const route_capture_storage_size = 16 * 1024;

pub const RequestContext = struct {
    server: *ServerContext,
    stream: *const std.Io.net.Stream,
    request: *std.http.Server.Request,
    started_at: std.Io.Timestamp,
    remote_address: []const u8 = "",
    response_status: ?u16 = null,
    authenticated_user_id: ?i64 = null,
    route_capture_entries: [max_route_captures]RouteCapture = undefined,
    route_capture_count: usize = 0,
    route_capture_storage: [route_capture_storage_size]u8 = undefined,
    route_capture_storage_used: usize = 0,

    pub fn init(
        server: *ServerContext,
        stream: *const std.Io.net.Stream,
        request: *std.http.Server.Request,
        started_at: std.Io.Timestamp,
        remote_address: []const u8,
    ) RequestContext {
        return .{
            .server = server,
            .stream = stream,
            .request = request,
            .started_at = started_at,
            .remote_address = remote_address,
        };
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

pub const Context = RequestContext;
