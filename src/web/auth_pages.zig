const std = @import("std");
const auth_crypto = @import("../auth/crypto.zig");
const context = @import("context.zig");
const form = @import("form.zig");
const layer = @import("layer.zig");
const route = @import("router.zig");
const resources = @import("resources.zig");
const support = @import("auth_support.zig");
const web_logging = @import("logging.zig");
const views = @import("auth_views.zig");

const RequestContext = context.RequestContext;
const Next = layer.Next;
const Error = anyerror;

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

const RecoveryCompleteForm = struct {
    token: []const u8,
    new_password: []const u8,
    new_password_confirmation: []const u8,
};

pub const Handler = struct {
    pub fn routes() []const route.Route {
        return routes_table.asSlice();
    }

    pub fn router() route.Router {
        return routes_table.router();
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
    .{ "GET /admin/recover/complete", getRecoveryComplete },
    .{ "POST /admin/recover/complete", postRecoveryComplete },
    resources.theme_css.route(),
    resources.auth_css.route(),
    resources.admin_css.route(),
    .{ "GET /admin", getLogin },
    .{ "GET /admin/", getLogin },
});

fn getLogin(request: *RequestContext, _: Next) Error!void {
    if (!try support.checkRequestOrigin(request)) return;
    const setup_available = request.server.identity_service.initialSetupAvailable() catch |failure| {
        web_logging.logDiagnostic(request, "error", "auth.setup_check_failed", "could not check initial setup availability", .internal_server_error, failure, null);
        return support.respondError(request, .internal_server_error);
    };
    if (setup_available) return support.redirectToRegistration(request);
    if (support.cookieValue(request, support.session_cookie_name)) |token| {
        if (request.server.identity_service.authenticate(token)) |session| {
            request.authenticated_user_id = session.user_id;
            return support.redirect(request, "/admin/editor", &.{});
        } else |failure| switch (failure) {
            error.InvalidSession => web_logging.logDiagnostic(request, "info", "auth.session_rejected", "login page session was rejected", .ok, failure, "invalid session"),
            else => {
                web_logging.logDiagnostic(request, "error", "auth.session_failed", "login page session lookup failed", .internal_server_error, failure, null);
                return support.respondError(request, .internal_server_error);
            },
        }
    }

    return renderLogin(request, null, .ok);
}

fn getRegister(request: *RequestContext, _: Next) Error!void {
    if (!try support.checkRequestOrigin(request)) return;
    const setup_available = request.server.identity_service.initialSetupAvailable() catch |failure| {
        web_logging.logDiagnostic(request, "error", "auth.setup_check_failed", "could not check initial setup availability", .internal_server_error, failure, null);
        return support.respondError(request, .internal_server_error);
    };
    if (!setup_available) return support.redirectToLogin(request);
    var token = try auth_crypto.newSecret(request.server.io);
    const cookie_buffer = try request.allocator().alloc(u8, 192);
    const cookie = try support.formatCookie(cookie_buffer, support.setup_csrf_cookie_name, &token, false);
    const body = views.register(request.allocator(), &token) catch |failure| return support.authViewFailure(request, failure);
    defer request.allocator().free(body);
    return support.respond(request, body, "text/html; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "set-cookie", .value = cookie },
    }, .ok);
}

fn postRegister(request: *RequestContext, _: Next) Error!void {
    if (!try support.checkRequestOrigin(request)) return;
    if (!try request.server.identity_service.initialSetupAvailable()) return support.redirectToLogin(request);
    const setup_cookie = support.cookieValue(request, support.setup_csrf_cookie_name);
    var parsed = form.extract(RegistrationForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "auth.registration_rejected", "registration form was rejected", .bad_request, failure, "invalid registration form");
        return support.respondError(request, .bad_request);
    };
    defer parsed.deinit(request.allocator());
    if (!try support.requireSetupCsrf(setup_cookie, parsed.value.csrf_token, request)) return;
    if (!std.mem.eql(u8, parsed.value.password, parsed.value.password_confirmation)) {
        web_logging.logDiagnostic(request, "warn", "auth.registration_rejected", "registration passwords did not match", .bad_request, null, "password confirmation mismatch");
        return support.respondError(request, .bad_request);
    }
    const credentials = request.server.identity_service.registerInitialLocalOwner(
        .{ .display_name = parsed.value.display_name, .email = parsed.value.email },
        parsed.value.login,
        parsed.value.password,
        request.remote_address,
    ) catch |registration_error| switch (registration_error) {
        error.OwnerAlreadyExists => {
            web_logging.logDiagnostic(request, "warn", "auth.registration_rejected", "initial owner already exists", .see_other, registration_error, "owner already exists");
            return support.redirectToLogin(request);
        },
        error.InvalidRegistration => {
            web_logging.logDiagnostic(request, "warn", "auth.registration_rejected", "registration was rejected", .bad_request, registration_error, "registration rate limit or policy rejection");
            return support.respondError(request, .bad_request);
        },
        error.InvalidLogin,
        error.InvalidDisplayName,
        error.InvalidEmail,
        error.InvalidPassword,
        error.InvalidPasswordHash,
        => {
            web_logging.logDiagnostic(request, "warn", "auth.registration_rejected", "registration fields failed validation", .bad_request, registration_error, support.registrationFailureReason(registration_error));
            return support.respondError(request, .bad_request);
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.registration_failed", "initial owner registration failed", .internal_server_error, registration_error, null);
            return support.respondError(request, .internal_server_error);
        },
    };
    return support.establishSession(request, credentials, "/admin/editor");
}

fn postLogin(request: *RequestContext, _: Next) Error!void {
    if (!try support.checkRequestOrigin(request)) return;
    if (support.cookieValue(request, support.session_cookie_name)) |token| {
        if (request.server.identity_service.authenticate(token)) |_| {
            const csrf = support.headerValue(request, "x-csrf-token") orelse {
                web_logging.logDiagnostic(request, "warn", "auth.login_rejected", "already authenticated login request had no CSRF token", .forbidden, null, "missing CSRF token");
                return support.respondError(request, .forbidden);
            };
            request.server.identity_service.validateCsrf(token, csrf) catch |failure| switch (failure) {
                error.InvalidCsrfToken => {
                    web_logging.logDiagnostic(request, "warn", "auth.login_rejected", "already authenticated login request failed CSRF validation", .forbidden, failure, "invalid CSRF token");
                    return support.respondError(request, .forbidden);
                },
                else => {
                    web_logging.logDiagnostic(request, "error", "auth.csrf_failed", "already authenticated login CSRF validation failed unexpectedly", .internal_server_error, failure, null);
                    return support.respondError(request, .internal_server_error);
                },
            };
        } else |failure| switch (failure) {
            error.InvalidSession => web_logging.logDiagnostic(request, "info", "auth.session_rejected", "existing login session was rejected", .forbidden, failure, "invalid session"),
            else => {
                web_logging.logDiagnostic(request, "error", "auth.session_failed", "existing login session lookup failed", .internal_server_error, failure, null);
                return support.respondError(request, .internal_server_error);
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
            return support.respondError(request, .internal_server_error);
        },
    };
    return support.establishSession(request, credentials, "/admin/editor");
}

fn postLogout(request: *RequestContext, _: Next) Error!void {
    if (!try support.checkRequestOrigin(request)) return;
    const token = support.cookieValue(request, support.session_cookie_name) orelse {
        web_logging.logDiagnostic(request, "warn", "auth.logout_rejected", "logout request had no session", .unauthorized, null, "missing session cookie");
        return support.respondError(request, .unauthorized);
    };
    var parsed = form.extract(LogoutForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "auth.logout_rejected", "logout form was rejected", .forbidden, failure, "invalid logout form");
        return support.respondError(request, .forbidden);
    };
    defer parsed.deinit(request.allocator());
    const csrf = support.headerValue(request, "x-csrf-token") orelse parsed.value.csrf_token orelse {
        web_logging.logDiagnostic(request, "warn", "auth.logout_rejected", "logout request had no CSRF token", .forbidden, null, "missing CSRF token");
        return support.respondError(request, .forbidden);
    };
    request.server.identity_service.validateCsrf(token, csrf) catch |failure| switch (failure) {
        error.InvalidCsrfToken => {
            web_logging.logDiagnostic(request, "warn", "auth.logout_rejected", "logout request failed CSRF validation", .forbidden, failure, "invalid CSRF token");
            return support.respondError(request, .forbidden);
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.logout_failed", "logout CSRF validation failed unexpectedly", .internal_server_error, failure, null);
            return support.respondError(request, .internal_server_error);
        },
    };
    request.server.identity_service.logout(token) catch |failure| {
        web_logging.logDiagnostic(request, "error", "auth.logout_failed", "logout failed", .internal_server_error, failure, null);
        return support.respondError(request, .internal_server_error);
    };
    return support.clearSession(request);
}

fn getPassword(request: *RequestContext, _: Next) Error!void {
    if (!try support.checkRequestOrigin(request)) return;
    const token = support.cookieValue(request, support.session_cookie_name) orelse return support.redirectToLogin(request);
    _ = request.server.identity_service.authenticate(token) catch |failure| switch (failure) {
        error.InvalidSession => {
            web_logging.logDiagnostic(request, "info", "auth.session_rejected", "password page session was rejected", .see_other, failure, "invalid session");
            return support.redirectToLogin(request);
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.session_failed", "password page session lookup failed", .internal_server_error, failure, null);
            return support.respondError(request, .internal_server_error);
        },
    };
    const csrf_token = support.cookieValue(request, support.csrf_cookie_name) orelse {
        web_logging.logDiagnostic(request, "warn", "auth.password_rejected", "password page had no CSRF cookie", .forbidden, null, "missing CSRF cookie");
        return support.respondError(request, .forbidden);
    };
    const body = views.password(request.allocator(), csrf_token) catch |failure| return support.authViewFailure(request, failure);
    defer request.allocator().free(body);
    return support.respond(request, body, "text/html; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
    }, .ok);
}

fn postPassword(request: *RequestContext, _: Next) Error!void {
    if (!try support.checkRequestOrigin(request)) return;
    const token = support.cookieValue(request, support.session_cookie_name) orelse {
        web_logging.logDiagnostic(request, "warn", "auth.password_rejected", "password change request had no session", .unauthorized, null, "missing session cookie");
        return support.respondError(request, .unauthorized);
    };
    _ = request.server.identity_service.authenticate(token) catch |failure| switch (failure) {
        error.InvalidSession => {
            web_logging.logDiagnostic(request, "warn", "auth.password_rejected", "password change session was rejected", .unauthorized, failure, "invalid session");
            return support.respondError(request, .unauthorized);
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.password_failed", "password change session lookup failed", .internal_server_error, failure, null);
            return support.respondError(request, .internal_server_error);
        },
    };
    var parsed = form.extract(PasswordForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "auth.password_rejected", "password change form was rejected", .bad_request, failure, "invalid password form");
        return support.respondError(request, .bad_request);
    };
    defer parsed.deinit(request.allocator());
    if (!try support.requireCsrf(request, token, parsed.value.csrf_token)) return;
    const credentials = request.server.identity_service.changePassword(token, parsed.value.current_password, parsed.value.new_password) catch |change_error| switch (change_error) {
        error.InvalidCredentials, error.InvalidPassword => {
            web_logging.logDiagnostic(request, "warn", "auth.password_rejected", "password change credentials were rejected", .unauthorized, change_error, "invalid password credentials");
            return support.respondError(request, .unauthorized);
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.password_failed", "password change failed", .internal_server_error, change_error, null);
            return support.respondError(request, .internal_server_error);
        },
    };
    return support.establishSession(request, credentials, "/admin/editor");
}

fn getRecoveryComplete(request: *RequestContext, _: Next) Error!void {
    if (!try support.checkRequestOrigin(request)) return;
    const body = views.recoveryComplete(request.allocator(), support.queryParam(request, "token") orelse "") catch |failure| return support.authViewFailure(request, failure);
    defer request.allocator().free(body);
    return support.respond(request, body, "text/html; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "referrer-policy", .value = "no-referrer" },
    }, .ok);
}

fn postRecoveryComplete(request: *RequestContext, _: Next) Error!void {
    if (!try support.checkRequestOrigin(request)) return;
    var parsed = form.extract(RecoveryCompleteForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "auth.recovery_rejected", "password recovery completion form was rejected", .unauthorized, failure, "invalid recovery completion form");
        return support.respondError(request, .unauthorized);
    };
    defer parsed.deinit(request.allocator());
    if (!recoveryPasswordsMatch(parsed.value)) {
        web_logging.logDiagnostic(
            request,
            "warn",
            "auth.recovery_rejected",
            "password recovery confirmation did not match",
            .bad_request,
            error.InvalidPasswordConfirmation,
            "password confirmation mismatch",
        );
        return support.respondError(request, .bad_request);
    }
    const credentials = request.server.identity_service.completePasswordReset(parsed.value.token, parsed.value.new_password) catch |reset_error| switch (reset_error) {
        error.InvalidCredentials, error.InvalidPassword => {
            web_logging.logDiagnostic(request, "warn", "auth.recovery_rejected", "password recovery credentials were rejected", .unauthorized, reset_error, "invalid recovery credentials");
            return support.respondError(request, .unauthorized);
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.recovery_failed", "password recovery completion failed", .internal_server_error, reset_error, null);
            return support.respondError(request, .internal_server_error);
        },
    };
    return support.establishSession(request, credentials, "/admin/editor");
}

fn recoveryPasswordsMatch(values: RecoveryCompleteForm) bool {
    return std.mem.eql(u8, values.new_password, values.new_password_confirmation);
}

test "password recovery requires matching password confirmation" {
    try std.testing.expect(recoveryPasswordsMatch(.{
        .token = "token",
        .new_password = "correct horse battery staple",
        .new_password_confirmation = "correct horse battery staple",
    }));
    try std.testing.expect(!recoveryPasswordsMatch(.{
        .token = "token",
        .new_password = "correct horse battery staple",
        .new_password_confirmation = "different correct horse battery staple",
    }));
}

fn renderLogin(request: *RequestContext, message: ?[]const u8, status: std.http.Status) Error!void {
    const body = views.login(request.allocator(), message) catch |failure| return support.authViewFailure(request, failure);
    defer request.allocator().free(body);
    return support.respond(request, body, "text/html; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
    }, status);
}

fn loginFailure(request: *RequestContext, message: []const u8, status: std.http.Status) Error!void {
    if (!support.isHtmx(request)) return renderLogin(request, message, status);
    const body = views.loginFeedback(request.allocator(), message) catch |failure| return support.authViewFailure(request, failure);
    defer request.allocator().free(body);
    return support.respond(request, body, "text/html; charset=utf-8", &.{
        .{ .name = "cache-control", .value = "no-store" },
    }, .ok);
}
