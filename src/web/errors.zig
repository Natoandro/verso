const std = @import("std");
const context = @import("context.zig");

const RequestContext = context.RequestContext;
const Error = anyerror;

/// Renders the generic HTML response for an HTTP error status.
///
/// Callers should use their own response when a form or HTMX request needs
/// field-level feedback. This page is for request-level failures that do not
/// have a more useful application response.
pub fn respond(request: *RequestContext, status: std.http.Status) Error!void {
    var body_buffer: [2048]u8 = undefined;
    const phrase = status.phrase() orelse "Request Error";
    const body = try std.fmt.bufPrint(&body_buffer, error_page_template, .{
        @intFromEnum(status),
        phrase,
        @intFromEnum(status),
        phrase,
        description(status),
    });

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

const error_page_template =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>{d} {s} - Verso</title>
    \\<style>
    \\body{{font-family:system-ui,sans-serif;line-height:1.5;margin:0;padding:2rem;color:#202124;background:#f7f7f5}}
    \\main{{max-width:42rem;margin:10vh auto;padding:2rem;background:#fff;border:1px solid #ddd;border-radius:.5rem}}
    \\.status{{font-size:.875rem;font-weight:700;letter-spacing:.08em;color:#666}}
    \\h1{{margin:.25rem 0 1rem}} a{{color:inherit}}
    \\</style></head><body><main>
    \\<p class="status">{d}</p><h1>{s}</h1><p>{s}</p>
    \\<p><a href="/">Return to the home page</a></p>
    \\</main></body></html>
;

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
