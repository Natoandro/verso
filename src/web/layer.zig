const context = @import("context.zig");
const std = @import("std");

pub const RequestContext = context.RequestContext;
pub const Context = context.Context;
pub const Error = anyerror;

pub const Next = struct {
    layers: []const Layer,
    index: usize,

    pub fn call(self: Next, request: *RequestContext) Error!void {
        if (self.index >= self.layers.len) return;
        return self.layers[self.index].handle(request, .{
            .layers = self.layers,
            .index = self.index + 1,
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

    pub fn handle(self: Layer, request: *RequestContext, next: Next) Error!void {
        return self.handle_fn(self.state, request, next);
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
