const std = @import("std");
const context = @import("context.zig");

const editor_html = @embedFile("editor.html");
const editor_css = @embedFile("editor.css");
const editor_js = @embedFile("editor.js");
const editor_model_js = @embedFile("editor_model.js");

pub const Handler = struct {
    pub fn handle(_: *@This(), request: *context.RequestContext, next: anytype) !void {
        const target = request.request.head.target;
        const path = if (std.mem.indexOfScalar(u8, target, '?')) |query_start| target[0..query_start] else target;
        const method = request.request.head.method;

        if (std.mem.eql(u8, path, "/admin/editor") or std.mem.eql(u8, path, "/admin/editor/")) {
            if (method != .GET) return respond(request, "The browser-local editor is read-only to the server.\n", .method_not_allowed, "text/plain; charset=utf-8", "GET");
            return respond(request, editor_html, .ok, "text/html; charset=utf-8", null);
        }
        if (std.mem.eql(u8, path, "/admin/editor.css")) {
            if (method != .GET) return respond(request, "Method not allowed\n", .method_not_allowed, "text/plain; charset=utf-8", "GET");
            return respond(request, editor_css, .ok, "text/css; charset=utf-8", null);
        }
        if (std.mem.eql(u8, path, "/admin/editor.js")) {
            if (method != .GET) return respond(request, "Method not allowed\n", .method_not_allowed, "text/plain; charset=utf-8", "GET");
            return respond(request, editor_js, .ok, "text/javascript; charset=utf-8", null);
        }
        if (std.mem.eql(u8, path, "/admin/editor-model.js")) {
            if (method != .GET) return respond(request, "Method not allowed\n", .method_not_allowed, "text/plain; charset=utf-8", "GET");
            return respond(request, editor_model_js, .ok, "text/javascript; charset=utf-8", null);
        }

        return next.call(request);
    }
};

fn respond(
    request: *context.RequestContext,
    body: []const u8,
    status: std.http.Status,
    content_type: []const u8,
    allow: ?[]const u8,
) !void {
    var headers: [3]std.http.Header = undefined;
    var header_count: usize = 1;
    headers[0] = .{ .name = "content-type", .value = content_type };
    if (allow) |allowed_methods| {
        headers[header_count] = .{ .name = "allow", .value = allowed_methods };
        header_count += 1;
    }
    headers[header_count] = .{ .name = "cache-control", .value = "no-store" };
    header_count += 1;
    request.request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = headers[0..header_count],
    }) catch |response_error| {
        if (response_error == error.Canceled) return error.Canceled;
        return response_error;
    };
    request.response_status = @intFromEnum(status);
}
