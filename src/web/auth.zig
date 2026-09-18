const std = @import("std");
const auth_crypto = @import("../auth/crypto.zig");
const auth_security = @import("../auth/security.zig");
const application_identity = @import("../application/identity.zig");
const context = @import("context.zig");
const form = @import("form.zig");
const layer = @import("layer.zig");
const route = @import("router.zig");

const RequestContext = context.RequestContext;
const Next = layer.Next;
const Layer = layer.Layer;
const Error = anyerror;

pub const session_cookie_name = "__Host-verso_session";
pub const csrf_cookie_name = "__Host-verso_csrf";

pub const Handler = struct {
    pub fn routes() []const route.Route {
        return routes_table.asSlice();
    }

    pub fn router() route.Router {
        return routes_table.router();
    }
};

pub const SessionGuard = struct {
    pub fn handle(_: *@This(), request: *RequestContext, next: Next) Error!void {
        if (!try checkRequestOrigin(request)) return;
        const token = cookieValue(request, session_cookie_name) orelse {
            return redirectToLogin(request);
        };
        const session = request.server.identity_service.authenticate(token) catch {
            return redirectToLogin(request);
        };
        if (auth_security.isUnsafeMethod(request.request.head.method)) {
            // HTMX sends the token as a header. Plain HTML form fallback is
            // checked by the protected mutation handler after it reads the
            // hidden csrf_token field; editor mutations do so before calling
            // an application service.
            if (headerValue(request, "x-csrf-token")) |csrf| {
                request.server.identity_service.validateCsrf(token, csrf) catch {
                    return respondText(request, "CSRF validation failed\n", .forbidden);
                };
            } else if (request.request.head.content_type == null or
                !std.ascii.eqlIgnoreCase(request.request.head.content_type.?, "application/x-www-form-urlencoded"))
            {
                return respondText(request, "CSRF validation failed\n", .forbidden);
            }
        }
        request.authenticated_user_id = session.user_id;
        return next.call(request);
    }
};

const routes_table = route.routes(.{
    .{ "GET /admin/login", getLogin },
    .{ "POST /admin/login", postLogin },
    .{ "POST /admin/logout", postLogout },
    .{ "GET /admin/password", getPassword },
    .{ "POST /admin/password", postPassword },
    .{ "GET /admin/recover", getRecovery },
    .{ "POST /admin/recover", postRecovery },
    .{ "GET /admin/recover/complete", getRecoveryComplete },
    .{ "POST /admin/recover/complete", postRecoveryComplete },
});

fn getLogin(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    if (cookieValue(request, session_cookie_name)) |token| {
        if (request.server.identity_service.authenticate(token)) |session| {
            request.authenticated_user_id = session.user_id;
            return redirect(request, "/admin/editor", &.{});
        } else |_| {}
    }

    return respond(request, login_html, "text/html; charset=utf-8", &[_]std.http.Header{
        .{ .name = "cache-control", .value = "no-store" },
    }, .ok);
}

fn postLogin(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    if (cookieValue(request, session_cookie_name)) |token| {
        if (request.server.identity_service.authenticate(token)) |_| {
            const csrf = headerValue(request, "x-csrf-token") orelse {
                return respondText(request, "CSRF validation failed\n", .forbidden);
            };
            request.server.identity_service.validateCsrf(token, csrf) catch {
                return respondText(request, "CSRF validation failed\n", .forbidden);
            };
        } else |_| {}
    }
    var values = form.read(request) catch {
        return respondText(request, "Invalid credentials\n", .unauthorized);
    };
    defer values.deinit(request.server.allocator);
    const login = values.login orelse return respondText(request, "Invalid credentials\n", .unauthorized);
    const password = values.password orelse return respondText(request, "Invalid credentials\n", .unauthorized);
    const credentials = request.server.identity_service.startLocalSession(
        login,
        password,
        request.remote_address,
    ) catch |login_error| switch (login_error) {
        error.InvalidCredentials => return respondText(request, "Invalid credentials\n", .unauthorized),
        else => return respondText(request, "Authentication failed\n", .internal_server_error),
    };
    return establishSession(request, credentials, "/admin/editor");
}

fn postLogout(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    const token = cookieValue(request, session_cookie_name) orelse
        return respondText(request, "Authentication required\n", .unauthorized);
    const csrf = headerValue(request, "x-csrf-token") orelse {
        return respondText(request, "CSRF validation failed\n", .forbidden);
    };
    request.server.identity_service.validateCsrf(token, csrf) catch {
        return respondText(request, "CSRF validation failed\n", .forbidden);
    };
    request.server.identity_service.logout(token) catch {
        return respondText(request, "Logout failed\n", .internal_server_error);
    };
    return clearSession(request);
}

fn getPassword(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    const token = cookieValue(request, session_cookie_name) orelse return redirectToLogin(request);
    _ = request.server.identity_service.authenticate(token) catch return redirectToLogin(request);
    const csrf_token = cookieValue(request, csrf_cookie_name) orelse
        return respondText(request, "CSRF validation failed\n", .forbidden);
    var html_buffer: [4096]u8 = undefined;
    const html = try std.fmt.bufPrint(&html_buffer,
        \\<!doctype html>
        \\<html lang="en"><head><meta charset="utf-8"><title>Change password</title></head>
        \\<body><main><h1>Change password</h1>
        \\<form method="post" action="/admin/password">
        \\<input type="hidden" name="csrf_token" value="{s}">
        \\<label>Current password <input type="password" name="current_password" autocomplete="current-password" required></label>
        \\<label>New password <input type="password" name="new_password" autocomplete="new-password" required></label>
        \\<button type="submit">Change password</button></form>
        \\</main></body></html>
    , .{csrf_token});
    return respond(request, html, "text/html; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
    }, .ok);
}

fn postPassword(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    const token = cookieValue(request, session_cookie_name) orelse
        return respondText(request, "Authentication required\n", .unauthorized);
    _ = request.server.identity_service.authenticate(token) catch
        return respondText(request, "Authentication required\n", .unauthorized);
    var values = form.read(request) catch {
        return respondText(request, "Invalid password\n", .bad_request);
    };
    defer values.deinit(request.server.allocator);
    if (!try requireCsrf(request, token, values.csrf_token)) return;
    const current = values.current_password orelse return respondText(request, "Invalid password\n", .bad_request);
    const new_password = values.new_password orelse return respondText(request, "Invalid password\n", .bad_request);
    const credentials = request.server.identity_service.changePassword(token, current, new_password) catch |change_error| switch (change_error) {
        error.InvalidCredentials, error.InvalidPassword => return respondText(request, "Invalid password\n", .unauthorized),
        else => return respondText(request, "Password change failed\n", .internal_server_error),
    };
    return establishSession(request, credentials, "/admin/editor");
}

fn getRecovery(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    return respond(request, recovery_html, "text/html; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
    }, .ok);
}

fn postRecovery(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    var values = form.read(request) catch {
        return respondText(request, "If the account exists, the recovery request was accepted.\n", .accepted);
    };
    defer values.deinit(request.server.allocator);
    if (values.login) |login| {
        _ = request.server.identity_service.requestPasswordReset(login, request.remote_address) catch {};
    }
    return respondText(request, "If the account exists, the recovery request was accepted.\n", .accepted);
}

fn getRecoveryComplete(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    return respond(request, recovery_complete_html, "text/html; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
    }, .ok);
}

fn postRecoveryComplete(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    var values = form.read(request) catch {
        return respondText(request, "Invalid recovery request\n", .unauthorized);
    };
    defer values.deinit(request.server.allocator);
    const reset_token = values.token orelse return respondText(request, "Invalid recovery request\n", .unauthorized);
    const new_password = values.new_password orelse return respondText(request, "Invalid recovery request\n", .unauthorized);
    const credentials = request.server.identity_service.completePasswordReset(reset_token, new_password) catch |reset_error| switch (reset_error) {
        error.InvalidCredentials, error.InvalidPassword => return respondText(request, "Invalid recovery request\n", .unauthorized),
        else => return respondText(request, "Recovery failed\n", .internal_server_error),
    };
    return establishSession(request, credentials, "/admin/editor");
}

pub fn requireCsrf(request: *RequestContext, token: []const u8, form_token: ?[]const u8) Error!bool {
    const csrf = headerValue(request, "x-csrf-token") orelse form_token orelse {
        try respondText(request, "CSRF validation failed\n", .forbidden);
        return false;
    };
    request.server.identity_service.validateCsrf(token, csrf) catch {
        try respondText(request, "CSRF validation failed\n", .forbidden);
        return false;
    };
    return true;
}

fn establishSession(
    request: *RequestContext,
    credentials: application_identity.SessionCredentials,
    location: []const u8,
) Error!void {
    var session_cookie_buffer: [192]u8 = undefined;
    var csrf_cookie_buffer: [192]u8 = undefined;
    const session_cookie = try formatCookie(&session_cookie_buffer, session_cookie_name, &credentials.token, true);
    const csrf_cookie = try formatCookie(&csrf_cookie_buffer, csrf_cookie_name, &credentials.csrf_token, false);
    return respond(request, &.{}, "text/plain; charset=utf-8", &.{
        .{ .name = "location", .value = location },
        .{ .name = "set-cookie", .value = session_cookie },
        .{ .name = "set-cookie", .value = csrf_cookie },
        .{ .name = "cache-control", .value = "no-store" },
    }, .see_other);
}

pub fn checkRequestOrigin(request: *RequestContext) !bool {
    const host = headerValue(request, "host") orelse {
        try respondText(request, "Bad request\n", .bad_request);
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
    }) catch {
        try respondText(request, "Origin rejected\n", .forbidden);
        return false;
    };
    return true;
}

fn clearSession(request: *RequestContext) Error!void {
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

fn redirect(
    request: *RequestContext,
    location: []const u8,
    extra_headers: []const std.http.Header,
) Error!void {
    var headers: [2]std.http.Header = undefined;
    headers[0] = .{ .name = "location", .value = location };
    var count: usize = 1;
    for (extra_headers) |header| {
        if (count == headers.len) return error.TooManyResponseHeaders;
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
        if (count == headers.len) return error.TooManyResponseHeaders;
        headers[count] = header;
        count += 1;
    }
    request.request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = headers[0..count],
    }) catch |response_error| {
        if (response_error == error.Canceled) return error.Canceled;
        return response_error;
    };
    request.response_status = @intFromEnum(status);
}

fn formatCookie(buffer: []u8, name: []const u8, value: []const u8, http_only: bool) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{s}={s}; Path=/; Secure; {s}SameSite=Lax",
        .{ name, value, if (http_only) "HttpOnly; " else "" },
    );
}

pub fn headerValue(request: *const RequestContext, name: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    var headers = request.request.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (result != null) return null;
        result = std.mem.trim(u8, header.value, " \t");
    }
    return result;
}

pub fn cookieValue(request: *const RequestContext, name: []const u8) ?[]const u8 {
    const header = headerValue(request, "cookie") orelse return null;
    var cookies = std.mem.splitScalar(u8, header, ';');
    while (cookies.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const separator = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (!std.mem.eql(u8, trimmed[0..separator], name)) continue;
        const value = trimmed[separator + 1 ..];
        if (value.len != auth_crypto.encoded_secret_length) return null;
        for (value) |character| {
            if (!std.ascii.isHex(character)) return null;
        }
        return value;
    }
    return null;
}

const login_html =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8"><title>Sign in</title></head>
    \\<body><main><h1>Sign in</h1>
    \\<form method="post" action="/admin/login">
    \\<label>Login <input name="login" autocomplete="username" required></label>
    \\<label>Password <input type="password" name="password" autocomplete="current-password" required></label>
    \\<button type="submit">Sign in</button></form>
    \\<p><a href="/admin/recover">Forgot your password?</a></p>
    \\</main></body></html>
;

const recovery_html =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8"><title>Password recovery</title></head>
    \\<body><main><h1>Password recovery</h1>
    \\<form method="post" action="/admin/recover">
    \\<label>Login <input name="login" autocomplete="username" required></label>
    \\<button type="submit">Request recovery</button></form>
    \\</main></body></html>
;

const recovery_complete_html =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8"><title>Set a new password</title></head>
    \\<body><main><h1>Set a new password</h1>
    \\<form method="post" action="/admin/recover/complete">
    \\<label>Recovery token <input name="token" autocomplete="one-time-code" required></label>
    \\<label>New password <input type="password" name="new_password" autocomplete="new-password" required></label>
    \\<button type="submit">Set password</button></form>
    \\</main></body></html>
;

test "cookie values reject malformed session credentials" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseCookieValue("bad"));
    try std.testing.expectEqual(@as(?[]const u8, null), parseCookieValue("0123"));
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        parseCookieValue("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef").?,
    );
}

fn parseCookieValue(value: []const u8) ?[]const u8 {
    if (value.len != auth_crypto.encoded_secret_length) return null;
    for (value) |character| if (!std.ascii.isHex(character)) return null;
    return value;
}

test "session and csrf cookie attributes are explicit" {
    var buffer: [192]u8 = undefined;
    const cookie = try formatCookie(&buffer, session_cookie_name, "token", true);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "Secure") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "SameSite=Lax") != null);
}

test "admin authentication routes separate login and logout methods" {
    const routes = Handler.routes();
    try std.testing.expectEqual(@as(?usize, 0), route.resolve(routes, .GET, "/admin/login"));
    try std.testing.expectEqual(@as(?usize, 1), route.resolve(routes, .POST, "/admin/login"));
    try std.testing.expectEqual(@as(?usize, 2), route.resolve(routes, .POST, "/admin/logout"));
    try std.testing.expectEqual(@as(?usize, null), route.resolve(routes, .GET, "/admin/logout"));
}
