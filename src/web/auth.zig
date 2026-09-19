const std = @import("std");
const auth_crypto = @import("../auth/crypto.zig");
const auth_security = @import("../auth/security.zig");
const application_identity = @import("../application/identity.zig");
const context = @import("context.zig");
const errors = @import("errors.zig");
const form = @import("form.zig");
const layer = @import("layer.zig");
const route = @import("router.zig");
const static_content = @import("static.zig");

const RequestContext = context.RequestContext;
const Next = layer.Next;
const Layer = layer.Layer;
const Error = anyerror;

const theme_css = @embedFile("styles/theme.css");
const auth_css = @embedFile("styles/auth.css");
const login_html = @embedFile("templates/pages/login.html");
const register_html_template = @embedFile("templates/pages/register.html");

pub const session_cookie_name = "__Host-verso_session";
pub const csrf_cookie_name = "__Host-verso_csrf";
const setup_csrf_cookie_name = "__Host-verso_setup_csrf";

const RegistrationForm = struct {
    csrf_token: ?[]const u8,
    display_name: []const u8,
    email: ?[]const u8,
    login: []const u8,
    password: []const u8,
    password_confirmation: []const u8,
};

const LoginForm = struct {
    login: []const u8,
    password: []const u8,
};

const PasswordForm = struct {
    csrf_token: ?[]const u8,
    current_password: []const u8,
    new_password: []const u8,
};

const RecoveryForm = struct {
    login: ?[]const u8,
};

const RecoveryCompleteForm = struct {
    token: []const u8,
    new_password: []const u8,
};

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
                    return errors.respond(request, .forbidden);
                };
            } else if (request.request.head.content_type == null or
                !std.ascii.eqlIgnoreCase(request.request.head.content_type.?, "application/x-www-form-urlencoded"))
            {
                return errors.respond(request, .forbidden);
            }
        }
        request.authenticated_user_id = session.user_id;
        return next.call(request);
    }
};

const routes_table = route.routes(.{
    .{ "GET /admin/login", getLogin },
    .{ "POST /admin/login", postLogin },
    .{ "GET /admin/register", getRegister },
    .{ "POST /admin/register", postRegister },
    .{ "POST /admin/logout", postLogout },
    .{ "GET /admin/password", getPassword },
    .{ "POST /admin/password", postPassword },
    .{ "GET /admin/recover", getRecovery },
    .{ "POST /admin/recover", postRecovery },
    .{ "GET /admin/recover/complete", getRecoveryComplete },
    .{ "POST /admin/recover/complete", postRecoveryComplete },
    .{ "GET /admin/theme.css", static_content.EmbeddedStatic.handler(
        theme_css,
        "text/css; charset=utf-8",
        .{ .status = .ok, .cache_control = "no-store" },
    ) },
    .{ "GET /admin/auth.css", static_content.EmbeddedStatic.handler(
        auth_css,
        "text/css; charset=utf-8",
        .{ .status = .ok, .cache_control = "no-store" },
    ) },
});

fn getLogin(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    const setup_available = request.server.identity_service.initialSetupAvailable() catch {
        return errors.respond(request, .internal_server_error);
    };
    if (setup_available) return redirectToRegistration(request);
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

fn getRegister(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    const setup_available = request.server.identity_service.initialSetupAvailable() catch {
        return errors.respond(request, .internal_server_error);
    };
    if (!setup_available) return redirectToLogin(request);
    var token = try auth_crypto.newSecret(request.server.io);
    var html_buffer: [4096]u8 = undefined;
    const html = try std.fmt.bufPrint(&html_buffer, register_html_template, .{&token});
    var cookie_buffer: [192]u8 = undefined;
    const cookie = try formatCookie(&cookie_buffer, setup_csrf_cookie_name, &token, false);
    return respond(request, html, "text/html; charset=utf-8", &[_]std.http.Header{
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "set-cookie", .value = cookie },
    }, .ok);
}

fn postRegister(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    if (!try request.server.identity_service.initialSetupAvailable()) return redirectToLogin(request);
    const setup_cookie = cookieValue(request, setup_csrf_cookie_name);
    var parsed = form.extract(RegistrationForm, request) catch {
        return errors.respond(request, .bad_request);
    };
    defer parsed.deinit(request.server.allocator);
    if (!try requireSetupCsrf(setup_cookie, parsed.value.csrf_token, request)) return;
    if (!std.mem.eql(u8, parsed.value.password, parsed.value.password_confirmation)) {
        return errors.respond(request, .bad_request);
    }
    const credentials = request.server.identity_service.registerInitialLocalOwner(
        .{ .display_name = parsed.value.display_name, .email = parsed.value.email },
        parsed.value.login,
        parsed.value.password,
        request.remote_address,
    ) catch |registration_error| switch (registration_error) {
        error.OwnerAlreadyExists => return redirectToLogin(request),
        error.InvalidRegistration => return errors.respond(request, .bad_request),
        else => return errors.respond(request, .internal_server_error),
    };
    return establishSession(request, credentials, "/admin/editor");
}

fn postLogin(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    if (cookieValue(request, session_cookie_name)) |token| {
        if (request.server.identity_service.authenticate(token)) |_| {
            const csrf = headerValue(request, "x-csrf-token") orelse {
                return errors.respond(request, .forbidden);
            };
            request.server.identity_service.validateCsrf(token, csrf) catch {
                return errors.respond(request, .forbidden);
            };
        } else |_| {}
    }
    var parsed = form.extract(LoginForm, request) catch {
        return errors.respond(request, .unauthorized);
    };
    defer parsed.deinit(request.server.allocator);
    const credentials = request.server.identity_service.startLocalSession(
        parsed.value.login,
        parsed.value.password,
        request.remote_address,
    ) catch |login_error| switch (login_error) {
        error.InvalidCredentials => return errors.respond(request, .unauthorized),
        else => return errors.respond(request, .internal_server_error),
    };
    return establishSession(request, credentials, "/admin/editor");
}

fn postLogout(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    const token = cookieValue(request, session_cookie_name) orelse
        return errors.respond(request, .unauthorized);
    const csrf = headerValue(request, "x-csrf-token") orelse {
        return errors.respond(request, .forbidden);
    };
    request.server.identity_service.validateCsrf(token, csrf) catch {
        return errors.respond(request, .forbidden);
    };
    request.server.identity_service.logout(token) catch {
        return errors.respond(request, .internal_server_error);
    };
    return clearSession(request);
}

fn getPassword(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    const token = cookieValue(request, session_cookie_name) orelse return redirectToLogin(request);
    _ = request.server.identity_service.authenticate(token) catch return redirectToLogin(request);
    const csrf_token = cookieValue(request, csrf_cookie_name) orelse
        return errors.respond(request, .forbidden);
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
        return errors.respond(request, .unauthorized);
    _ = request.server.identity_service.authenticate(token) catch
        return errors.respond(request, .unauthorized);
    var parsed = form.extract(PasswordForm, request) catch {
        return errors.respond(request, .bad_request);
    };
    defer parsed.deinit(request.server.allocator);
    if (!try requireCsrf(request, token, parsed.value.csrf_token)) return;
    const credentials = request.server.identity_service.changePassword(token, parsed.value.current_password, parsed.value.new_password) catch |change_error| switch (change_error) {
        error.InvalidCredentials, error.InvalidPassword => return errors.respond(request, .unauthorized),
        else => return errors.respond(request, .internal_server_error),
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
    var parsed = form.extract(RecoveryForm, request) catch {
        return respondText(request, "If the account exists, the recovery request was accepted.\n", .accepted);
    };
    defer parsed.deinit(request.server.allocator);
    if (parsed.value.login) |login| {
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
    var parsed = form.extract(RecoveryCompleteForm, request) catch {
        return errors.respond(request, .unauthorized);
    };
    defer parsed.deinit(request.server.allocator);
    const credentials = request.server.identity_service.completePasswordReset(parsed.value.token, parsed.value.new_password) catch |reset_error| switch (reset_error) {
        error.InvalidCredentials, error.InvalidPassword => return errors.respond(request, .unauthorized),
        else => return errors.respond(request, .internal_server_error),
    };
    return establishSession(request, credentials, "/admin/editor");
}

pub fn requireCsrf(request: *RequestContext, token: []const u8, form_token: ?[]const u8) Error!bool {
    const csrf = headerValue(request, "x-csrf-token") orelse form_token orelse {
        try errors.respond(request, .forbidden);
        return false;
    };
    request.server.identity_service.validateCsrf(token, csrf) catch {
        try errors.respond(request, .forbidden);
        return false;
    };
    return true;
}

fn requireSetupCsrf(cookie: ?[]const u8, form_token: ?[]const u8, request: *RequestContext) Error!bool {
    const cookie_value = cookie orelse {
        try errors.respond(request, .forbidden);
        return false;
    };
    const token = form_token orelse {
        try errors.respond(request, .forbidden);
        return false;
    };
    if (!auth_crypto.constantTimeEqual(cookie_value, token)) {
        try errors.respond(request, .forbidden);
        return false;
    }
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
    }) catch {
        try errors.respond(request, .forbidden);
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

pub fn redirectToRegistration(request: *RequestContext) Error!void {
    return redirect(request, "/admin/register", &.{
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
    return request.cachedHeaderValue(name);
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
    try std.testing.expectEqual(@as(?usize, 2), route.resolve(routes, .GET, "/admin/register"));
    try std.testing.expectEqual(@as(?usize, 3), route.resolve(routes, .POST, "/admin/register"));
    try std.testing.expectEqual(@as(?usize, 4), route.resolve(routes, .POST, "/admin/logout"));
    try std.testing.expectEqual(@as(?usize, null), route.resolve(routes, .GET, "/admin/logout"));
}
