const context = @import("context.zig");
const layer = @import("layer.zig");

const RequestContext = context.RequestContext;
const Next = layer.Next;
const Error = layer.Error;

/// Caches the configured request headers before downstream layers run.
pub const HeaderCacheLayer = struct {
    names: []const []const u8,

    pub fn handle(self: *@This(), request: *RequestContext, next: Next) Error!void {
        try request.cacheHeaders(self.names);
        return next.call(request);
    }
};
