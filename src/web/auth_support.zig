const std = @import("std");
const auth_crypto = @import("../auth/crypto.zig");
const auth_cookies = @import("auth_cookies.zig");
const auth_security = @import("../auth/security.zig");
const application_identity = @import("../application/identity.zig");
const context = @import("context.zig");
const errors = @import("errors.zig");
const layer = @import("layer.zig");
const web_logging = @import("logging.zig");

pub const cookieValue = auth_cookies.value;
pub const formatCookie = auth_cookies.formatCookie;
pub const respondError = errors.respond;

const RequestContext = context.RequestContext;
const Next = layer.Next;
const Error = anyerror;

pub const session_cookie_name = "__Host-verso_session";
pub const csrf_cookie_name = "__Host-verso_csrf";
pub const setup_csrf_cookie_name = "__Host-verso_setup_csrf";

pub const SessionGuard = struct {
    pub fn handle(_: *@This(), request: *RequestContext, next: Next) Error!void {
        if (!try checkRequestOrigin(request)) return;
        const token = cookieValue(request, session_cookie_name) orelse {
            web_logging.logDiagnostic(request, "info", "auth.session_rejected", "protected request had no session", .see_other, null, "missing session cookie");
            return redirectToLogin(request);
        };
        const session = request.server.identity_service.authenticate(token) catch |failure| switch (failure) {
            error.InvalidSession => {
                web_logging.logDiagnostic(request, "info", "auth.session_rejected", "session authentication failed", .see_other, failure, "invalid session");
                return redirectToLogin(request);
            },
            else => {
                web_logging.logDiagnostic(request, "error", "auth.session_failed", "session authentication failed unexpectedly", .internal_server_error, failure, null);
                return errors.respond(request, .internal_server_error);
            },
        };
        if (auth_security.isUnsafeMethod(request.request.head.method)) {
            // HTMX sends the token as a header. Plain HTML form fallback is
            // checked by the protected mutation handler after it reads the
            // hidden csrf_token field; editor mutations do so before calling
            // an application service.
            if (headerValue(request, "x-csrf-token")) |csrf| {
                request.server.identity_service.validateCsrf(token, csrf) catch |failure| switch (failure) {
                    error.InvalidCsrfToken => {
                        web_logging.logDiagnostic(request, "warn", "auth.csrf_rejected", "request failed CSRF validation", .forbidden, failure, "invalid CSRF token");
                        return errors.respond(request, .forbidden);
                    },
                    else => {
                        web_logging.logDiagnostic(request, "error", "auth.csrf_failed", "CSRF validation failed unexpectedly", .internal_server_error, failure, null);
                        return errors.respond(request, .internal_server_error);
                    },
                };
            } else if (request.request.head.content_type == null or
                !std.ascii.eqlIgnoreCase(request.request.head.content_type.?, "application/x-www-form-urlencoded"))
            {
                web_logging.logDiagnostic(request, "warn", "auth.csrf_rejected", "unsafe request had no acceptable CSRF form", .forbidden, null, "missing CSRF token");
                return errors.respond(request, .forbidden);
            }
        }
        request.authenticated_user_id = session.user_id;
        return next.call(request);
    }
};

pub fn requireCsrf(request: *RequestContext, token: []const u8, form_token: ?[]const u8) Error!bool {
    const csrf = headerValue(request, "x-csrf-token") orelse form_token orelse {
        web_logging.logDiagnostic(request, "warn", "auth.csrf_rejected", "request had no CSRF token", .forbidden, null, "missing CSRF token");
        try errors.respond(request, .forbidden);
        return false;
    };
    request.server.identity_service.validateCsrf(token, csrf) catch |failure| switch (failure) {
        error.InvalidCsrfToken => {
            web_logging.logDiagnostic(request, "warn", "auth.csrf_rejected", "request failed CSRF validation", .forbidden, failure, "invalid CSRF token");
            try errors.respond(request, .forbidden);
            return false;
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.csrf_failed", "CSRF validation failed unexpectedly", .internal_server_error, failure, null);
            try errors.respond(request, .internal_server_error);
            return false;
        },
    };
    return true;
}

pub fn requireSetupCsrf(cookie: ?[]const u8, form_token: ?[]const u8, request: *RequestContext) Error!bool {
    const cookie_value = cookie orelse {
        web_logging.logDiagnostic(request, "warn", "auth.setup_csrf_rejected", "registration had no setup CSRF cookie", .forbidden, null, "missing setup CSRF cookie");
        try errors.respond(request, .forbidden);
        return false;
    };
    const token = form_token orelse {
        web_logging.logDiagnostic(request, "warn", "auth.setup_csrf_rejected", "registration had no setup CSRF form token", .forbidden, null, "missing setup CSRF form token");
        try errors.respond(request, .forbidden);
        return false;
    };
    if (!auth_crypto.constantTimeEqual(cookie_value, token)) {
        web_logging.logDiagnostic(request, "warn", "auth.setup_csrf_rejected", "registration setup CSRF validation failed", .forbidden, null, "invalid setup CSRF token");
        try errors.respond(request, .forbidden);
        return false;
    }
    return true;
}

pub fn establishSession(
    request: *RequestContext,
    credentials: application_identity.SessionCredentials,
    location: []const u8,
) Error!void {
    const session_cookie_buffer = try request.allocator().alloc(u8, 192);
    const csrf_cookie_buffer = try request.allocator().alloc(u8, 192);
    const session_cookie = try formatCookie(session_cookie_buffer, session_cookie_name, &credentials.token, true);
    const csrf_cookie = try formatCookie(csrf_cookie_buffer, csrf_cookie_name, &credentials.csrf_token, false);
    if (isHtmx(request)) return respond(request, &.{}, "text/plain; charset=utf-8", &.{
        .{ .name = "hx-redirect", .value = location },
        .{ .name = "set-cookie", .value = session_cookie },
        .{ .name = "set-cookie", .value = csrf_cookie },
        .{ .name = "cache-control", .value = "no-store" },
    }, .ok);
    return respond(request, &.{}, "text/plain; charset=utf-8", &.{
        .{ .name = "location", .value = location },
        .{ .name = "set-cookie", .value = session_cookie },
        .{ .name = "set-cookie", .value = csrf_cookie },
        .{ .name = "cache-control", .value = "no-store" },
    }, .see_other);
}

pub fn authViewFailure(request: *RequestContext, failure: anyerror) Error {
    web_logging.logDiagnostic(request, "error", "auth.template_render_failed", "authentication page rendering failed", .internal_server_error, failure, null);
    return failure;
}

pub fn isHtmx(request: *RequestContext) bool {
    return headerValue(request, "hx-request") != null;
}

pub fn checkRequestOrigin(request: *RequestContext) !bool {
    const host = headerValue(request, "host") orelse {
        web_logging.logDiagnostic(request, "warn", "http.origin_rejected", "request had no Host header", .bad_request, null, "missing Host header");
        try errors.respond(request, .bad_request);
        return false;
    };
    const forwarded_scheme = headerValue(request, "x-forwarded-proto");
    const forwarded_host = headerValue(request, "x-forwarded-host");
    request.server.origin_policy.check(.{
        .method = request.request.head.method,
        .scheme = "http",
        .host = host,
        .remote_address = request.remote_address,
        .origin = headerValue(request, "origin"),
        .forwarded_scheme = forwarded_scheme,
        .forwarded_host = forwarded_host,
    }, request.allocator()) catch |failure| switch (failure) {
        error.IncompleteForwardedOrigin,
        error.UntrustedForwardedOrigin,
        error.InvalidForwardedScheme,
        error.InvalidForwardedHost,
        error.InvalidPublicOrigin,
        error.MissingOrigin,
        error.OriginNotAllowed,
        error.InvalidOrigin,
        => {
            web_logging.logDiagnostic(request, "warn", "http.origin_rejected", "request origin validation failed", .forbidden, failure, "origin policy rejected request");
            try errors.respond(request, .forbidden);
            return false;
        },
        else => {
            web_logging.logDiagnostic(request, "error", "http.origin_check_failed", "request origin validation failed unexpectedly", .internal_server_error, failure, null);
            try errors.respond(request, .internal_server_error);
            return false;
        },
    };
    return true;
}

pub fn clearSession(request: *RequestContext) Error!void {
    const headers = [_]std.http.Header{
        .{ .name = "location", .value = "/admin/login" },
        .{ .name = "set-cookie", .value = "__Host-verso_session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax" },
        .{ .name = "set-cookie", .value = "__Host-verso_csrf=; Path=/; Max-Age=0; Secure; SameSite=Lax" },
        .{ .name = "cache-control", .value = "no-store" },
    };
    return respond(request, &.{}, "text/plain; charset=utf-8", &headers, .see_other);
}

pub fn redirectToLogin(request: *RequestContext) Error!void {
    return redirect(request, "/admin/login", &.{
        .{ .name = "cache-control", .value = "no-store" },
    });
}

pub fn redirectToRegistration(request: *RequestContext) Error!void {
    return redirect(request, "/admin/register", &.{
        .{ .name = "cache-control", .value = "no-store" },
    });
}

pub fn redirect(
    request: *RequestContext,
    location: []const u8,
    extra_headers: []const std.http.Header,
) Error!void {
    var headers: [2]std.http.Header = undefined;
    headers[0] = .{ .name = "location", .value = location };
    var count: usize = 1;
    for (extra_headers) |header| {
        if (count == headers.len) {
            web_logging.logDiagnostic(request, "error", "http.response_failed", "response contained too many headers", .internal_server_error, error.TooManyResponseHeaders, null);
            return error.TooManyResponseHeaders;
        }
        headers[count] = header;
        count += 1;
    }
    return respond(request, &.{}, "text/plain; charset=utf-8", headers[0..count], .see_other);
}

pub fn respondText(request: *RequestContext, body: []const u8, status: std.http.Status) Error!void {
    return respond(request, body, "text/plain; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
    }, status);
}

pub fn respond(
    request: *RequestContext,
    body: []const u8,
    content_type: []const u8,
    extra_headers: []const std.http.Header,
    status: std.http.Status,
) Error!void {
    var headers: [6]std.http.Header = undefined;
    headers[0] = .{ .name = "content-type", .value = content_type };
    var count: usize = 1;
    for (extra_headers) |header| {
        if (count == headers.len) {
            web_logging.logDiagnostic(request, "error", "http.response_failed", "response contained too many headers", status, error.TooManyResponseHeaders, null);
            return error.TooManyResponseHeaders;
        }
        headers[count] = header;
        count += 1;
    }
    request.request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = headers[0..count],
    }) catch |response_error| {
        if (response_error == error.Canceled) return error.Canceled;
        web_logging.logDiagnostic(request, "error", "http.response_failed", "failed to write HTTP response", status, response_error, null);
        return response_error;
    };
    request.response_status = @intFromEnum(status);
}

pub fn headerValue(request: *const RequestContext, name: []const u8) ?[]const u8 {
    return request.cachedHeaderValue(name);
}

pub fn queryParam(request: *const RequestContext, name: []const u8) ?[]const u8 {
    const target = request.requestTarget();
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const separator = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..separator], name)) return pair[separator + 1 ..];
    }
    return null;
}

pub fn registrationFailureReason(failure: anyerror) []const u8 {
    return switch (failure) {
        error.InvalidLogin => "login policy rejected value",
        error.InvalidDisplayName => "display name policy rejected value",
        error.InvalidEmail => "email policy rejected value",
        error.InvalidPassword => "password policy requires 12 to 1024 characters and no NUL bytes",
        error.InvalidPasswordHash => "password hash policy rejected value",
        else => "registration field validation failed",
    };
}
