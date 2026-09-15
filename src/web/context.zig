const std = @import("std");
const config = @import("../config.zig");
const logging = @import("../logging.zig");

pub const ServerContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *const config.Config,
    logger: *logging.Logger,
};

pub const RequestContext = struct {
    server: *ServerContext,
    stream: *const std.Io.net.Stream,
    request: *std.http.Server.Request,
    started_at: std.Io.Timestamp,
    response_status: ?u16 = null,

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
};

pub const Context = RequestContext;
