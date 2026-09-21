const std = @import("std");
const context = @import("context.zig");
const tmpl = @import("tmpl");
const web_logging = @import("logging.zig");

const RequestContext = context.RequestContext;
const Error = anyerror;
const theme_css = @embedFile("styles/theme.css");
const error_css = @embedFile("styles/error.css");
const error_page_template = tmpl.parse(@embedFile("templates/pages/error.html"), .{});

/// Renders the generic HTML response for an HTTP error status.
///
/// Callers should use their own response when a form or HTMX request needs
/// field-level feedback. This page is for request-level failures that do not
/// have a more useful application response.
pub fn respond(request: *RequestContext, status: std.http.Status) Error!void {
    const body_buffer = request.allocator().alloc(u8, 32768) catch |failure| {
        web_logging.logDiagnostic(request, "error", "http.error_response_failed", "could not allocate an HTTP error response", status, failure, null);
        return failure;
    };
    const phrase = status.phrase() orelse "Request Error";
    var writer = std.Io.Writer.fixed(body_buffer);
    error_page_template.render(&writer, .{
        .status_code = @intFromEnum(status),
        .phrase = phrase,
        .theme_css = theme_css,
        .error_css = error_css,
        .description = description(status),
    }) catch |failure| {
        web_logging.logDiagnostic(request, "error", "http.error_response_failed", "could not render an HTTP error response", status, failure, null);
        return failure;
    };
    const body = writer.buffered();

    request.request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "x-content-type-options", .value = "nosniff" },
            .{ .name = "referrer-policy", .value = "no-referrer" },
        },
    }) catch |response_error| {
        if (response_error == error.Canceled) return error.Canceled;
        web_logging.logDiagnostic(request, "error", "http.error_response_failed", "could not write an HTTP error response", status, response_error, null);
        return response_error;
    };
    request.response_status = @intFromEnum(status);
}

fn description(status: std.http.Status) []const u8 {
    return switch (status) {
        .bad_request => "The request could not be understood.",
        .unauthorized => "You need to sign in to continue.",
        .forbidden => "You do not have permission to access this resource.",
        .not_found => "The page you requested could not be found.",
        .method_not_allowed => "This method is not supported for this resource.",
        .payload_too_large => "The request is too large to process.",
        .unsupported_media_type => "This request format is not supported.",
        .too_many_requests => "Too many requests. Please try again later.",
        .internal_server_error => "Something went wrong on our side.",
        .bad_gateway => "The upstream service returned an invalid response.",
        .service_unavailable => "The service is temporarily unavailable.",
        .gateway_timeout => "The upstream service took too long to respond.",
        else => "The request could not be completed.",
    };
}

test "generic error descriptions cover common statuses" {
    try std.testing.expectEqualStrings(
        "The page you requested could not be found.",
        description(.not_found),
    );
    try std.testing.expectEqualStrings(
        "The request could not be completed.",
        description(.request_timeout),
    );
}
