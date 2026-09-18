const std = @import("std");
const config = @import("../config.zig");
const logging = @import("../logging.zig");

pub const ServerContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *const config.Config,
    logger: *logging.Logger,
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
    response_status: ?u16 = null,
    route_capture_entries: [max_route_captures]RouteCapture = undefined,
    route_capture_count: usize = 0,
    route_capture_storage: [route_capture_storage_size]u8 = undefined,
    route_capture_storage_used: usize = 0,

    pub fn init(
        server: *ServerContext,
        stream: *const std.Io.net.Stream,
        request: *std.http.Server.Request,
        started_at: std.Io.Timestamp,
    ) RequestContext {
        return .{
            .server = server,
            .stream = stream,
            .request = request,
            .started_at = started_at,
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
