const std = @import("std");
const auth_crypto = @import("../auth/crypto.zig");
const auth_cookies = @import("auth_cookies.zig");
const auth_security = @import("../auth/security.zig");
const application_identity = @import("../application/identity.zig");
const context = @import("context.zig");
const errors = @import("errors.zig");
const form = @import("form.zig");
const layer = @import("layer.zig");
const route = @import("router.zig");
const static_content = @import("static.zig");
const web_logging = @import("logging.zig");
const views = @import("auth_views.zig");

pub const cookieValue = auth_cookies.value;
const formatCookie = auth_cookies.formatCookie;

const RequestContext = context.RequestContext;
const Next = layer.Next;
const Layer = layer.Layer;
const Error = anyerror;

const theme_css = @embedFile("styles/theme.css");
const auth_css = @embedFile("styles/auth.css");
const admin_css = @embedFile("styles/admin.css");

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

const LogoutForm = struct {
    csrf_token: ?[]const u8,
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
    .{ "GET /admin/admin.css", static_content.EmbeddedStatic.handler(
        admin_css,
        "text/css; charset=utf-8",
        .{ .status = .ok, .cache_control = "no-store" },
    ) },
    .{ "GET /admin", getLogin },
    .{ "GET /admin/", getLogin },
});

fn getLogin(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    const setup_available = request.server.identity_service.initialSetupAvailable() catch |failure| {
        web_logging.logDiagnostic(request, "error", "auth.setup_check_failed", "could not check initial setup availability", .internal_server_error, failure, null);
        return errors.respond(request, .internal_server_error);
    };
    if (setup_available) return redirectToRegistration(request);
    if (cookieValue(request, session_cookie_name)) |token| {
        if (request.server.identity_service.authenticate(token)) |session| {
            request.authenticated_user_id = session.user_id;
            return redirect(request, "/admin/editor", &.{});
        } else |failure| switch (failure) {
            error.InvalidSession => web_logging.logDiagnostic(request, "info", "auth.session_rejected", "login page session was rejected", .ok, failure, "invalid session"),
            else => {
                web_logging.logDiagnostic(request, "error", "auth.session_failed", "login page session lookup failed", .internal_server_error, failure, null);
                return errors.respond(request, .internal_server_error);
            },
        }
    }

    return renderLogin(request, null, .ok);
}

fn getRegister(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    const setup_available = request.server.identity_service.initialSetupAvailable() catch |failure| {
        web_logging.logDiagnostic(request, "error", "auth.setup_check_failed", "could not check initial setup availability", .internal_server_error, failure, null);
        return errors.respond(request, .internal_server_error);
    };
    if (!setup_available) return redirectToLogin(request);
    var token = try auth_crypto.newSecret(request.server.io);
    const cookie_buffer = try request.allocator().alloc(u8, 192);
    const cookie = try formatCookie(cookie_buffer, setup_csrf_cookie_name, &token, false);
    const body = views.register(request.allocator(), &token) catch |failure| return authViewFailure(request, failure);
    defer request.allocator().free(body);
    return respond(request, body, "text/html; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "set-cookie", .value = cookie },
    }, .ok);
}

fn postRegister(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    if (!try request.server.identity_service.initialSetupAvailable()) return redirectToLogin(request);
    const setup_cookie = cookieValue(request, setup_csrf_cookie_name);
    var parsed = form.extract(RegistrationForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "auth.registration_rejected", "registration form was rejected", .bad_request, failure, "invalid registration form");
        return errors.respond(request, .bad_request);
    };
    defer parsed.deinit(request.allocator());
    if (!try requireSetupCsrf(setup_cookie, parsed.value.csrf_token, request)) return;
    if (!std.mem.eql(u8, parsed.value.password, parsed.value.password_confirmation)) {
        web_logging.logDiagnostic(request, "warn", "auth.registration_rejected", "registration passwords did not match", .bad_request, null, "password confirmation mismatch");
        return errors.respond(request, .bad_request);
    }
    const credentials = request.server.identity_service.registerInitialLocalOwner(
        .{ .display_name = parsed.value.display_name, .email = parsed.value.email },
        parsed.value.login,
        parsed.value.password,
        request.remote_address,
    ) catch |registration_error| switch (registration_error) {
        error.OwnerAlreadyExists => {
            web_logging.logDiagnostic(request, "warn", "auth.registration_rejected", "initial owner already exists", .see_other, registration_error, "owner already exists");
            return redirectToLogin(request);
        },
        error.InvalidRegistration => {
            web_logging.logDiagnostic(request, "warn", "auth.registration_rejected", "registration was rejected", .bad_request, registration_error, "registration rate limit or policy rejection");
            return errors.respond(request, .bad_request);
        },
        error.InvalidLogin,
        error.InvalidDisplayName,
        error.InvalidEmail,
        error.InvalidPassword,
        error.InvalidPasswordHash,
        => {
            web_logging.logDiagnostic(request, "warn", "auth.registration_rejected", "registration fields failed validation", .bad_request, registration_error, registrationFailureReason(registration_error));
            return errors.respond(request, .bad_request);
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.registration_failed", "initial owner registration failed", .internal_server_error, registration_error, null);
            return errors.respond(request, .internal_server_error);
        },
    };
    return establishSession(request, credentials, "/admin/editor");
}

fn registrationFailureReason(failure: anyerror) []const u8 {
    return switch (failure) {
        error.InvalidLogin => "login policy rejected value",
        error.InvalidDisplayName => "display name policy rejected value",
        error.InvalidEmail => "email policy rejected value",
        error.InvalidPassword => "password policy requires 12 to 1024 characters and no NUL bytes",
        error.InvalidPasswordHash => "password hash policy rejected value",
        else => "registration field validation failed",
    };
}

fn postLogin(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    if (cookieValue(request, session_cookie_name)) |token| {
        if (request.server.identity_service.authenticate(token)) |_| {
            const csrf = headerValue(request, "x-csrf-token") orelse {
                web_logging.logDiagnostic(request, "warn", "auth.login_rejected", "already authenticated login request had no CSRF token", .forbidden, null, "missing CSRF token");
                return errors.respond(request, .forbidden);
            };
            request.server.identity_service.validateCsrf(token, csrf) catch |failure| switch (failure) {
                error.InvalidCsrfToken => {
                    web_logging.logDiagnostic(request, "warn", "auth.login_rejected", "already authenticated login request failed CSRF validation", .forbidden, failure, "invalid CSRF token");
                    return errors.respond(request, .forbidden);
                },
                else => {
                    web_logging.logDiagnostic(request, "error", "auth.csrf_failed", "already authenticated login CSRF validation failed unexpectedly", .internal_server_error, failure, null);
                    return errors.respond(request, .internal_server_error);
                },
            };
        } else |failure| switch (failure) {
            error.InvalidSession => web_logging.logDiagnostic(request, "info", "auth.session_rejected", "existing login session was rejected", .forbidden, failure, "invalid session"),
            else => {
                web_logging.logDiagnostic(request, "error", "auth.session_failed", "existing login session lookup failed", .internal_server_error, failure, null);
                return errors.respond(request, .internal_server_error);
            },
        }
    }
    var parsed = form.extract(LoginForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "auth.login_rejected", "login form was rejected", .unauthorized, failure, "invalid login form");
        return loginFailure(request, "Enter your login and password.", .unauthorized);
    };
    defer parsed.deinit(request.allocator());
    const credentials = request.server.identity_service.startLocalSession(
        parsed.value.login,
        parsed.value.password,
        request.remote_address,
    ) catch |login_error| switch (login_error) {
        error.InvalidCredentials => {
            web_logging.logDiagnostic(request, "warn", "auth.login_rejected", "login credentials were rejected", .unauthorized, login_error, "invalid credentials");
            return loginFailure(request, "The login or password is incorrect.", .unauthorized);
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.login_failed", "local login failed", .internal_server_error, login_error, null);
            return errors.respond(request, .internal_server_error);
        },
    };
    return establishSession(request, credentials, "/admin/editor");
}

fn postLogout(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    const token = cookieValue(request, session_cookie_name) orelse {
        web_logging.logDiagnostic(request, "warn", "auth.logout_rejected", "logout request had no session", .unauthorized, null, "missing session cookie");
        return errors.respond(request, .unauthorized);
    };
    var parsed = form.extract(LogoutForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "auth.logout_rejected", "logout form was rejected", .forbidden, failure, "invalid logout form");
        return errors.respond(request, .forbidden);
    };
    defer parsed.deinit(request.allocator());
    const csrf = headerValue(request, "x-csrf-token") orelse parsed.value.csrf_token orelse {
        web_logging.logDiagnostic(request, "warn", "auth.logout_rejected", "logout request had no CSRF token", .forbidden, null, "missing CSRF token");
        return errors.respond(request, .forbidden);
    };
    request.server.identity_service.validateCsrf(token, csrf) catch |failure| switch (failure) {
        error.InvalidCsrfToken => {
            web_logging.logDiagnostic(request, "warn", "auth.logout_rejected", "logout request failed CSRF validation", .forbidden, failure, "invalid CSRF token");
            return errors.respond(request, .forbidden);
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.logout_failed", "logout CSRF validation failed unexpectedly", .internal_server_error, failure, null);
            return errors.respond(request, .internal_server_error);
        },
    };
    request.server.identity_service.logout(token) catch |failure| {
        web_logging.logDiagnostic(request, "error", "auth.logout_failed", "logout failed", .internal_server_error, failure, null);
        return errors.respond(request, .internal_server_error);
    };
    return clearSession(request);
}

fn getPassword(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    const token = cookieValue(request, session_cookie_name) orelse return redirectToLogin(request);
    _ = request.server.identity_service.authenticate(token) catch |failure| switch (failure) {
        error.InvalidSession => {
            web_logging.logDiagnostic(request, "info", "auth.session_rejected", "password page session was rejected", .see_other, failure, "invalid session");
            return redirectToLogin(request);
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.session_failed", "password page session lookup failed", .internal_server_error, failure, null);
            return errors.respond(request, .internal_server_error);
        },
    };
    const csrf_token = cookieValue(request, csrf_cookie_name) orelse {
        web_logging.logDiagnostic(request, "warn", "auth.password_rejected", "password page had no CSRF cookie", .forbidden, null, "missing CSRF cookie");
        return errors.respond(request, .forbidden);
    };
    const body = views.password(request.allocator(), csrf_token) catch |failure| return authViewFailure(request, failure);
    defer request.allocator().free(body);
    return respond(request, body, "text/html; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
    }, .ok);
}

fn postPassword(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    const token = cookieValue(request, session_cookie_name) orelse {
        web_logging.logDiagnostic(request, "warn", "auth.password_rejected", "password change request had no session", .unauthorized, null, "missing session cookie");
        return errors.respond(request, .unauthorized);
    };
    _ = request.server.identity_service.authenticate(token) catch |failure| switch (failure) {
        error.InvalidSession => {
            web_logging.logDiagnostic(request, "warn", "auth.password_rejected", "password change session was rejected", .unauthorized, failure, "invalid session");
            return errors.respond(request, .unauthorized);
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.password_failed", "password change session lookup failed", .internal_server_error, failure, null);
            return errors.respond(request, .internal_server_error);
        },
    };
    var parsed = form.extract(PasswordForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "auth.password_rejected", "password change form was rejected", .bad_request, failure, "invalid password form");
        return errors.respond(request, .bad_request);
    };
    defer parsed.deinit(request.allocator());
    if (!try requireCsrf(request, token, parsed.value.csrf_token)) return;
    const credentials = request.server.identity_service.changePassword(token, parsed.value.current_password, parsed.value.new_password) catch |change_error| switch (change_error) {
        error.InvalidCredentials, error.InvalidPassword => {
            web_logging.logDiagnostic(request, "warn", "auth.password_rejected", "password change credentials were rejected", .unauthorized, change_error, "invalid password credentials");
            return errors.respond(request, .unauthorized);
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.password_failed", "password change failed", .internal_server_error, change_error, null);
            return errors.respond(request, .internal_server_error);
        },
    };
    return establishSession(request, credentials, "/admin/editor");
}

fn getRecovery(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    const body = views.recovery(request.allocator()) catch |failure| return authViewFailure(request, failure);
    defer request.allocator().free(body);
    return respond(request, body, "text/html; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
    }, .ok);
}

fn postRecovery(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    var parsed = form.extract(RecoveryForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "auth.recovery_rejected", "password recovery form was rejected", .accepted, failure, "invalid recovery form");
        return respondText(request, "If the account exists, the recovery request was accepted.\n", .accepted);
    };
    defer parsed.deinit(request.allocator());
    if (parsed.value.login) |login| {
        _ = request.server.identity_service.requestPasswordReset(login, request.remote_address) catch |failure| {
            web_logging.logDiagnostic(request, "error", "auth.recovery_failed", "password recovery operation failed", .accepted, failure, null);
        };
    }
    return respondText(request, "If the account exists, the recovery request was accepted.\n", .accepted);
}

fn getRecoveryComplete(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    const body = views.recoveryComplete(request.allocator()) catch |failure| return authViewFailure(request, failure);
    defer request.allocator().free(body);
    return respond(request, body, "text/html; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
    }, .ok);
}

fn postRecoveryComplete(request: *RequestContext, _: Next) Error!void {
    if (!try checkRequestOrigin(request)) return;
    var parsed = form.extract(RecoveryCompleteForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "auth.recovery_rejected", "password recovery completion form was rejected", .unauthorized, failure, "invalid recovery completion form");
        return errors.respond(request, .unauthorized);
    };
    defer parsed.deinit(request.allocator());
    const credentials = request.server.identity_service.completePasswordReset(parsed.value.token, parsed.value.new_password) catch |reset_error| switch (reset_error) {
        error.InvalidCredentials, error.InvalidPassword => {
            web_logging.logDiagnostic(request, "warn", "auth.recovery_rejected", "password recovery credentials were rejected", .unauthorized, reset_error, "invalid recovery credentials");
            return errors.respond(request, .unauthorized);
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.recovery_failed", "password recovery completion failed", .internal_server_error, reset_error, null);
            return errors.respond(request, .internal_server_error);
        },
    };
    return establishSession(request, credentials, "/admin/editor");
}

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

fn requireSetupCsrf(cookie: ?[]const u8, form_token: ?[]const u8, request: *RequestContext) Error!bool {
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

fn establishSession(
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

fn renderLogin(request: *RequestContext, message: ?[]const u8, status: std.http.Status) Error!void {
    const body = views.login(request.allocator(), message) catch |failure| return authViewFailure(request, failure);
    defer request.allocator().free(body);
    return respond(request, body, "text/html; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
    }, status);
}

fn loginFailure(request: *RequestContext, message: []const u8, status: std.http.Status) Error!void {
    if (!isHtmx(request)) return renderLogin(request, message, status);
    const body = views.loginFeedback(request.allocator(), message) catch |failure| return authViewFailure(request, failure);
    defer request.allocator().free(body);
    return respond(request, body, "text/html; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
    }, .ok);
}

fn authViewFailure(request: *RequestContext, failure: anyerror) Error {
    web_logging.logDiagnostic(request, "error", "auth.template_render_failed", "authentication page rendering failed", .internal_server_error, failure, null);
    return failure;
}

fn isHtmx(request: *const RequestContext) bool {
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
