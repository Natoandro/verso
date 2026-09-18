const std = @import("std");
const context = @import("context.zig");
const layer = @import("layer.zig");

pub const RequestContext = context.RequestContext;
pub const RouteCapture = context.RouteCapture;
pub const Next = layer.Next;
pub const Layer = layer.Layer;
pub const Error = anyerror;
const max_route_segments = 32;
const max_target_segments = 64;
const max_decoded_segment = 4096;

const SegmentKind = enum { literal, parameter };

const Segment = struct {
    kind: SegmentKind,
    text: []const u8,
};

const RouteScore = struct { literal_segments: usize, segment_count: usize };

const TargetSegment = struct { raw: []const u8 };

const Target = struct {
    path: []const u8,
    segments: [max_target_segments]TargetSegment = undefined,
    segment_count: usize = 0,
    trailing_slash: bool = false,
};

pub const Route = struct {
    method: std.http.Method,
    path: []const u8,
    handler: Layer,
    trailing_slash: bool = false,

    // A zero segment count with compiled=false retains literal-route compatibility.
    segments: [max_route_segments]Segment = undefined,
    segment_count: usize = 0,
    literal_segment_count: usize = 0,
    compiled: bool = false,
    slash_required: bool = false,
};
pub fn RouteTable(comptime count: usize) type {
    return struct {
        items: [count]Route,

        pub fn asSlice(self: *const @This()) []const Route {
            return self.items[0..];
        }

        pub fn router(self: *const @This()) Router {
            return Router.init(self.asSlice());
        }

        pub fn handle(self: *@This(), request: *RequestContext, next: Next) Error!void {
            return dispatch(self.asSlice(), request, next);
        }

        pub fn layer(self: *@This()) Layer {
            return Layer.init(self);
        }
    };
}
/// Compiles route declarations such as .{"GET /articles/{id}", handler}.
/// The returned table owns the compact route representations; no pattern
/// parsing is performed during server startup.
pub fn routes(comptime declarations: anytype) RouteTable(declarations.len) {
    @setEvalBranchQuota(20_000 + declarations.len * 2_000);
    var compiled: [declarations.len]Route = undefined;

    inline for (declarations, 0..) |declaration, index| {
        const declaration_type = @TypeOf(declaration);
        const pattern = if (@hasField(declaration_type, "pattern")) declaration.pattern else declaration[0];
        const handler_value = if (@hasField(declaration_type, "handler")) declaration.handler else declaration[1];
        compiled[index] = compilePattern(pattern, handler_value);
    }

    comptime validateDeclarations(declarations);
    return .{ .items = compiled };
}

pub fn compile(comptime pattern: []const u8, handler: anytype) Route {
    return compilePattern(pattern, handler);
}

fn compilePattern(comptime pattern: []const u8, handler_value: anytype) Route {
    var route = comptime compilePatternStructure(pattern);
    route.handler = toLayer(handler_value);
    return route;
}

fn compilePatternStructure(comptime pattern: []const u8) Route {
    const method_end = std.mem.indexOfScalar(u8, pattern, ' ') orelse
        @compileError(std.fmt.comptimePrint("malformed route pattern '{s}': expected METHOD /path", .{pattern}));
    if (method_end == 0 or method_end + 1 >= pattern.len or pattern[method_end + 1] != '/') {
        @compileError(std.fmt.comptimePrint("malformed route pattern '{s}': expected METHOD /path", .{pattern}));
    }
    if (std.mem.indexOfScalarPos(u8, pattern, method_end + 1, ' ') != null or
        std.mem.indexOfScalar(u8, pattern[0..method_end], '\t') != null)
    {
        @compileError(std.fmt.comptimePrint("malformed route pattern '{s}': unexpected whitespace", .{pattern}));
    }

    const method_text = pattern[0..method_end];
    const method = std.meta.stringToEnum(std.http.Method, method_text) orelse
        @compileError(std.fmt.comptimePrint("invalid HTTP method in route pattern '{s}'", .{pattern}));
    const path = pattern[method_end + 1 ..];
    if (path.len == 0 or path[0] != '/') {
        @compileError(std.fmt.comptimePrint("malformed route pattern '{s}': path must start with '/'", .{pattern}));
    }

    comptime var route: Route = .{
        .method = method,
        .path = path,
        .handler = undefined,
        .compiled = true,
    };
    comptime parsePath(pattern, path, &route);
    return route;
}

fn toLayer(handler_value: anytype) Layer {
    return Layer.fromHandler(handler_value);
}

fn parsePath(comptime pattern: []const u8, path: []const u8, route: *Route) void {
    if (path.len == 1) {
        route.slash_required = true;
        return;
    }

    var path_end = path.len;
    if (path[path_end - 1] == '/') {
        route.slash_required = true;
        path_end -= 1;
        if (path_end == 0 or path[path_end - 1] == '/') {
            @compileError(std.fmt.comptimePrint("malformed route pattern '{s}': empty path segment", .{pattern}));
        }
    }

    var cursor: usize = 1;
    while (cursor < path_end) {
        if (route.segment_count == max_route_segments) {
            @compileError(std.fmt.comptimePrint("route pattern '{s}' has too many path segments", .{pattern}));
        }

        const segment_start = cursor;
        while (cursor < path_end and path[cursor] != '/') : (cursor += 1) {}
        if (cursor == segment_start) {
            @compileError(std.fmt.comptimePrint("malformed route pattern '{s}': empty path segment", .{pattern}));
        }

        const segment = path[segment_start..cursor];
        if (segment[0] == '{' or segment[segment.len - 1] == '}') {
            if (segment.len < 3 or segment[0] != '{' or segment[segment.len - 1] != '}') {
                @compileError(std.fmt.comptimePrint("malformed route pattern '{s}': malformed parameter", .{pattern}));
            }
            const body = segment[1 .. segment.len - 1];
            if (std.mem.endsWith(u8, body, "...")) {
                @compileError(std.fmt.comptimePrint("trailing wildcard is reserved and not enabled in route pattern '{s}'", .{pattern}));
            }
            if (!isIdentifier(body)) {
                @compileError(std.fmt.comptimePrint("malformed route pattern '{s}': invalid parameter name", .{pattern}));
            }
            for (route.segments[0..route.segment_count]) |existing| {
                if (existing.kind == .parameter and std.mem.eql(u8, existing.text, body)) {
                    @compileError(std.fmt.comptimePrint("duplicate route parameter '{s}' in pattern '{s}'", .{ body, pattern }));
                }
            }
            route.segments[route.segment_count] = .{ .kind = .parameter, .text = body };
            route.segment_count += 1;
        } else {
            if (std.mem.indexOfAny(u8, segment, "{}%\\?#") != null or
                std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
            {
                @compileError(std.fmt.comptimePrint("malformed route pattern '{s}': invalid literal segment", .{pattern}));
            }
            for (segment) |character| {
                if (character <= 0x20 or character == 0x7f) {
                    @compileError(std.fmt.comptimePrint("malformed route pattern '{s}': invalid literal segment", .{pattern}));
                }
            }
            route.segments[route.segment_count] = .{ .kind = .literal, .text = segment };
            route.segment_count += 1;
            route.literal_segment_count += 1;
        }

        if (cursor < path_end) cursor += 1;
    }
}

fn isIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value, 0..) |character, index| {
        const valid = (character >= 'a' and character <= 'z') or
            (character >= 'A' and character <= 'Z') or
            (character == '_') or
            (index != 0 and character >= '0' and character <= '9');
        if (!valid) return false;
    }
    return true;
}

fn validateDeclarations(comptime declarations: anytype) void {
    inline for (declarations, 0..) |left_declaration, left_index| {
        const left_type = @TypeOf(left_declaration);
        const left_pattern = if (@hasField(left_type, "pattern")) left_declaration.pattern else left_declaration[0];
        const left = compilePatternStructure(left_pattern);
        inline for (declarations, 0..) |right_declaration, right_index| {
            if (right_index <= left_index) continue;
            const right_type = @TypeOf(right_declaration);
            const right_pattern = if (@hasField(right_type, "pattern")) right_declaration.pattern else right_declaration[0];
            const right = compilePatternStructure(right_pattern);
            if (left.method != right.method) continue;
            if (!sameScore(left, right)) continue;
            @compileError(std.fmt.comptimePrint(
                "ambiguous route declarations '{s} {s}' and '{s} {s}'",
                .{ @tagName(left.method), left.path, @tagName(right.method), right.path },
            ));
        }
    }
}

fn sameScore(left: Route, right: Route) bool {
    return left.literal_segment_count == right.literal_segment_count and
        left.segment_count == right.segment_count and
        left.slash_required == right.slash_required;
}

pub const Router = struct {
    routes: []const Route,

    pub fn init(routes_table: []const Route) Router {
        return .{ .routes = routes_table };
    }

    pub fn handle(self: *Router, request: *RequestContext, next: Next) Error!void {
        return dispatch(self.routes, request, next);
    }
};

fn dispatch(routes_table: []const Route, request: *RequestContext, next: Next) Error!void {
    request.clearRouteCaptures();
    const target = parseTarget(request.request.head.target) orelse return next.call(request);
    const index = findBest(routes_table, request.request.head.method, target) orelse
        return next.call(request);
    defer request.clearRouteCaptures();

    populateCaptures(&routes_table[index], target, request) catch |capture_error| return capture_error;
    return routes_table[index].handler.handle(request, next);
}

pub fn resolve(routes_table: []const Route, method: std.http.Method, target: []const u8) ?usize {
    const parsed_target = parseTarget(target) orelse return null;
    return findBest(routes_table, method, parsed_target);
}

fn findBest(routes_table: []const Route, method: std.http.Method, target: Target) ?usize {
    var best: ?usize = null;
    var best_score = RouteScore{ .literal_segments = 0, .segment_count = 0 };
    for (routes_table, 0..) |route, index| {
        if (route.method != method or !matches(route, target)) continue;
        const route_score = score(route);
        if (best == null or scoreIsMoreSpecific(route_score, best_score)) {
            best = index;
            best_score = route_score;
        }
    }
    return best;
}

fn score(route: Route) RouteScore {
    if (!route.compiled) {
        const segment_count = countPathSegments(route.path);
        return .{ .literal_segments = segment_count, .segment_count = segment_count };
    }
    return .{ .literal_segments = route.literal_segment_count, .segment_count = route.segment_count };
}

fn scoreIsMoreSpecific(candidate: RouteScore, current: RouteScore) bool {
    if (candidate.literal_segments != current.literal_segments) return candidate.literal_segments > current.literal_segments;
    return candidate.segment_count > current.segment_count;
}

fn matches(route: Route, target: Target) bool {
    if (!route.compiled) {
        if (std.mem.eql(u8, target.path, route.path)) return true;
        return route.trailing_slash and target.path.len == route.path.len + 1 and
            std.mem.startsWith(u8, target.path, route.path) and target.path[target.path.len - 1] == '/';
    }
    if (route.segment_count != target.segment_count or route.slash_required != target.trailing_slash) return false;

    for (route.segments[0..route.segment_count], target.segments[0..target.segment_count]) |route_segment, target_segment| {
        var decoded: [max_decoded_segment]u8 = undefined;
        const value = decodeSegment(target_segment.raw, &decoded) catch return false;
        if (route_segment.kind == .literal and !std.mem.eql(u8, route_segment.text, value)) return false;
        if (route_segment.kind == .parameter and (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, ".."))) return false;
    }
    return true;
}

fn populateCaptures(route: *const Route, target: Target, request: *RequestContext) !void {
    if (!route.compiled) return;
    for (route.segments[0..route.segment_count], target.segments[0..target.segment_count]) |route_segment, target_segment| {
        if (route_segment.kind != .parameter) continue;
        if (request.route_capture_count == request.route_capture_entries.len) return error.TooManyRouteCaptures;
        var decoded: [max_decoded_segment]u8 = undefined;
        const value = try decodeSegment(target_segment.raw, &decoded);
        if (request.route_capture_storage_used + value.len > request.route_capture_storage.len) return error.RouteCaptureTooLarge;
        const start = request.route_capture_storage_used;
        @memcpy(request.route_capture_storage[start .. start + value.len], value);
        request.route_capture_storage_used += value.len;
        request.route_capture_entries[request.route_capture_count] = .{
            .name = route_segment.text,
            .value = request.route_capture_storage[start .. start + value.len],
        };
        request.route_capture_count += 1;
    }
}

fn parseTarget(target: []const u8) ?Target {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..query_start];
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, '#') != null) return null;

    var parsed = Target{ .path = path };
    if (path.len == 1) {
        parsed.trailing_slash = true;
        return parsed;
    }

    var path_end = path.len;
    if (path[path_end - 1] == '/') {
        parsed.trailing_slash = true;
        path_end -= 1;
        if (path_end == 0 or path[path_end - 1] == '/') return null;
    }

    var cursor: usize = 1;
    while (cursor < path_end) {
        if (parsed.segment_count == max_target_segments) return null;
        const segment_start = cursor;
        while (cursor < path_end and path[cursor] != '/') : (cursor += 1) {}
        if (cursor == segment_start) return null;
        const raw = path[segment_start..cursor];
        var decoded: [max_decoded_segment]u8 = undefined;
        const value = decodeSegment(raw, &decoded) catch return null;
        if (std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return null;
        parsed.segments[parsed.segment_count] = .{ .raw = raw };
        parsed.segment_count += 1;
        if (cursor < path_end) cursor += 1;
    }
    return parsed;
}

fn decodeSegment(raw: []const u8, output: []u8) ![]const u8 {
    var output_len: usize = 0;
    var cursor: usize = 0;
    while (cursor < raw.len) {
        if (output_len == output.len) return error.TargetTooLong;
        var value = raw[cursor];
        if (value == '%') {
            if (cursor + 2 >= raw.len) return error.MalformedTarget;
            const high = hexValue(raw[cursor + 1]) orelse return error.MalformedTarget;
            const low = hexValue(raw[cursor + 2]) orelse return error.MalformedTarget;
            value = (high << 4) | low;
            cursor += 3;
        } else {
            cursor += 1;
        }
        if (value == '/' or value == '\\' or value < 0x20 or value == 0x7f) {
            return error.UnsafeTarget;
        }
        output[output_len] = value;
        output_len += 1;
    }
    return output[0..output_len];
}

fn hexValue(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => null,
    };
}

fn countPathSegments(path: []const u8) usize {
    if (std.mem.eql(u8, path, "/")) return 0;
    var count: usize = 1;
    for (path) |character| {
        if (character == '/') count += 1;
    }
    if (path[path.len - 1] == '/') count -= 1;
    return count;
}
