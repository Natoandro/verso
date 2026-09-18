const context = @import("context.zig");
const std = @import("std");

pub const RequestContext = context.RequestContext;
pub const Context = context.Context;
pub const Error = anyerror;

pub const Next = struct {
    layers: []const Layer,
    index: usize,
    fallback: ?*const Next = null,

    pub fn call(self: Next, request: *RequestContext) Error!void {
        if (self.index >= self.layers.len) {
            if (self.fallback) |fallback| return fallback.call(request);
            return;
        }
        return self.layers[self.index].handle(request, .{
            .layers = self.layers,
            .index = self.index + 1,
            .fallback = self.fallback,
        });
    }
};

pub const Layer = struct {
    state: *anyopaque,
    handle_fn: *const fn (*anyopaque, *RequestContext, Next) Error!void,

    /// Wraps a pointer to a value with a `handle(*RequestContext, Next)` method.
    ///
    /// The value may be a middleware, final handler, or service. A middleware
    /// calls `next.call(request)`; a final handler simply does not call it.
    pub fn init(instance: anytype) Layer {
        const Instance = @TypeOf(instance);
        const Adapter = struct {
            fn handle(state: *anyopaque, request: *RequestContext, next: Next) Error!void {
                const typed: Instance = @ptrCast(@alignCast(state));
                return typed.handle(request, next);
            }
        };

        return .{
            .state = @ptrCast(instance),
            .handle_fn = Adapter.handle,
        };
    }

    pub fn initFn(comptime handler_fn: *const fn (*RequestContext, Next) Error!void) Layer {
        const Adapter = struct {
            fn handle(_: *anyopaque, request: *RequestContext, next: Next) Error!void {
                return handler_fn(request, next);
            }
        };

        return .{
            .state = undefined,
            .handle_fn = Adapter.handle,
        };
    }

    pub fn fromHandler(handler_value: anytype) Layer {
        if (@TypeOf(handler_value) == Layer) return handler_value;
        return initFn(handler_value);
    }

    pub fn handle(self: Layer, request: *RequestContext, next: Next) Error!void {
        return self.handle_fn(self.state, request, next);
    }
};

/// Builds a route handler from ordinary layers. The outer `next` remains the
/// terminal continuation after the composed layers have run.
pub fn compose(comptime handlers: anytype) Layer {
    return Layer.initFn(composedHandler(handlers));
}

fn composedHandler(comptime handlers: anytype) *const fn (*RequestContext, Next) Error!void {
    return struct {
        fn handle(request: *RequestContext, next: Next) Error!void {
            var layers: [handlers.len]Layer = undefined;
            inline for (handlers, 0..) |handler, index| {
                layers[index] = Layer.fromHandler(handler);
            }

            var fallback = next;
            return (Next{
                .layers = &layers,
                .index = 0,
                .fallback = &fallback,
            }).call(request);
        }
    }.handle;
}

/// Mounts a layer below a path namespace. Once the namespace is claimed,
/// unmatched routes cannot fall through to an unrelated outer layer.
pub const Mount = struct {
    namespace: []const u8,
    inner: Layer,
    fallback: ?Layer = null,

    pub fn init(comptime namespace: []const u8, inner: Layer) Mount {
        validateNamespace(namespace);
        return .{ .namespace = namespace, .inner = inner };
    }

    pub fn initWithFallback(comptime namespace: []const u8, inner: Layer, fallback: Layer) Mount {
        validateNamespace(namespace);
        return .{ .namespace = namespace, .inner = inner, .fallback = fallback };
    }

    pub fn handle(self: *Mount, request: *RequestContext, next: Next) Error!void {
        if (!claims(self.namespace, request.request.head.target)) return next.call(request);

        var terminal_layers: [1]Layer = undefined;
        const terminal = if (self.fallback) |fallback| blk: {
            terminal_layers[0] = fallback;
            break :blk Next{ .layers = &terminal_layers, .index = 0 };
        } else Next{ .layers = &.{}, .index = 0 };
        return self.inner.handle(request, terminal);
    }

    fn validateNamespace(comptime namespace: []const u8) void {
        if (namespace.len == 0 or namespace[0] != '/') {
            @compileError("mounted route namespace must start with '/'");
        }
        if (namespace.len > 1 and namespace[namespace.len - 1] == '/') {
            @compileError("mounted route namespace must not have a trailing slash");
        }
        const has_delimiter = comptime blk: {
            var found = false;
            for (namespace) |character| {
                if (character == '?' or character == '#') found = true;
            }
            break :blk found;
        };
        if (has_delimiter) {
            @compileError("mounted route namespace must not contain query or fragment delimiters");
        }
    }

    fn claims(namespace: []const u8, target: []const u8) bool {
        const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
        const path = target[0..path_end];
        if (std.mem.eql(u8, namespace, "/")) return path.len > 0 and path[0] == '/';
        if (std.mem.eql(u8, path, namespace)) return true;
        return path.len > namespace.len and
            std.mem.startsWith(u8, path, namespace) and
            path[namespace.len] == '/';
    }
};

pub const Pipeline = struct {
    layers: []const Layer,

    pub fn init(layers: []const Layer) Pipeline {
        return .{ .layers = layers };
    }

    pub fn handle(self: Pipeline, request: *RequestContext) Error!void {
        return (Next{ .layers = self.layers, .index = 0 }).call(request);
    }
};

test "pipeline composes middleware and final handlers" {
    const Recorder = struct {
        events: *[4]u8,
        index: *usize,
        before: u8,
        after: ?u8,

        pub fn handle(self: *@This(), request: *RequestContext, next: Next) Error!void {
            self.events[self.index.*] = self.before;
            self.index.* += 1;
            if (self.after) |event| {
                try next.call(request);
                self.events[self.index.*] = event;
                self.index.* += 1;
            }
        }
    };

    var events: [4]u8 = .{ 0, 0, 0, 0 };
    var index: usize = 0;
    var middleware = Recorder{
        .events = &events,
        .index = &index,
        .before = 1,
        .after = 4,
    };
    var final_handler = Recorder{
        .events = &events,
        .index = &index,
        .before = 2,
        .after = null,
    };
    const layers = [_]Layer{ .init(&middleware), .init(&final_handler) };
    const pipeline = Pipeline.init(&layers);

    var request: RequestContext = undefined;
    try pipeline.handle(&request);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 4, 0 }, &events);
    try std.testing.expectEqual(@as(usize, 3), index);
}

test "pipeline propagates handler errors" {
    const Failing = struct {
        pub fn handle(_: *@This(), _: *RequestContext, _: Next) Error!void {
            return error.HandlerFailed;
        }
    };

    var failing = Failing{};
    const layers = [_]Layer{.init(&failing)};
    const pipeline = Pipeline.init(&layers);
    var request: RequestContext = undefined;

    try std.testing.expectError(error.HandlerFailed, pipeline.handle(&request));
}

test "composed layers delegate through their outer continuation" {
    const auth = struct {
        fn handle(request: *RequestContext, next: Next) Error!void {
            request.response_status = 1;
            return next.call(request);
        }
    }.handle;
    const final = struct {
        fn handle(request: *RequestContext, next: Next) Error!void {
            if (request.response_status != 1) return error.AuthorizationWasSkipped;
            request.response_status = 2;
            return next.call(request);
        }
    }.handle;
    const outer = struct {
        fn handle(request: *RequestContext, _: Next) Error!void {
            if (request.response_status != 2) return error.RouteHandlerDidNotDelegate;
        }
    }.handle;

    var request: RequestContext = undefined;
    request.response_status = null;
    const outer_layers = [_]Layer{Layer.initFn(outer)};
    const composed = compose(.{ auth, final });
    try composed.handle(&request, .{ .layers = &outer_layers, .index = 0 });
    try std.testing.expectEqual(@as(?u16, 2), request.response_status);
}

test "a mount claims its namespace without claiming similar prefixes" {
    const inner = struct {
        fn handle(request: *RequestContext, _: Next) Error!void {
            request.response_status = 200;
        }
    }.handle;
    const outer = struct {
        fn handle(request: *RequestContext, _: Next) Error!void {
            request.response_status = 404;
        }
    }.handle;

    var mount = Mount.init("/admin", Layer.initFn(inner));
    const outer_layers = [_]Layer{Layer.initFn(outer)};
    var http_request: std.http.Server.Request = undefined;
    var request: RequestContext = undefined;
    request.request = &http_request;

    http_request.head.target = "/administer";
    request.response_status = null;
    try mount.handle(&request, .{ .layers = &outer_layers, .index = 0 });
    try std.testing.expectEqual(@as(?u16, 404), request.response_status);

    http_request.head.target = "/admin/missing";
    request.response_status = null;
    try mount.handle(&request, .{ .layers = &outer_layers, .index = 0 });
    try std.testing.expectEqual(@as(?u16, 200), request.response_status);
}
