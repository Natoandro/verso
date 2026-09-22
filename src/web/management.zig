const std = @import("std");
const domain = @import("../domain/identity.zig");
const auth = @import("auth.zig");
const context = @import("context.zig");
const errors = @import("errors.zig");
const form = @import("form.zig");
const layer = @import("layer.zig");
const management = @import("../application/identity_management.zig");
const routing = @import("router.zig");
const templates = @import("templates/root.zig");
const web_logging = @import("logging.zig");

const RequestContext = context.RequestContext;
const Next = layer.Next;
const Error = anyerror;

const AuthorForm = struct {
    csrf_token: ?[]const u8,
    display_name: []const u8,
    slug: []const u8,
    biography: ?[]const u8,
};

const AssignmentForm = struct {
    csrf_token: ?[]const u8,
    editor_user_id: i64,
    scope_type: []const u8,
    scope_id: i64,
};

const RevokeAssignmentForm = struct {
    csrf_token: ?[]const u8,
    expected_revision: i64,
};

pub const Handler = struct {
    pub fn router() routing.Router {
        return routes_table.router();
    }
};

const routes_table = routing.routes(.{
    .{ "GET /admin/authors", getAuthors },
    .{ "POST /admin/authors", postCreateAuthor },
    .{ "POST /admin/authors/{id}", postUpdateAuthor },
    .{ "POST /admin/assignments", postCreateAssignment },
    .{ "POST /admin/assignments/{id}/revoke", postRevokeAssignment },
});

fn getAuthors(request: *RequestContext, _: Next) Error!void {
    const token = (try managerToken(request)) orelse return;
    var snapshot = request.server.identity_management_service.listWithAllocator(request.allocator(), token) catch |list_error| {
        return managementError(request, list_error);
    };
    defer snapshot.deinit();
    return renderAuthors(request, snapshot);
}

fn postCreateAuthor(request: *RequestContext, _: Next) Error!void {
    const token = (try managerToken(request)) orelse return;
    var parsed = form.extract(AuthorForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "management.request_rejected", "author form was rejected", .bad_request, failure, "invalid author form");
        return auth.respondText(request, "Invalid author form\n", .bad_request);
    };
    defer parsed.deinit(request.allocator());
    if (!try auth.requireCsrf(request, token, parsed.value.csrf_token)) return;

    const display_name = parsed.value.display_name;
    const slug = parsed.value.slug;
    _ = request.server.identity_service.createAuthor(token, .{
        .display_name = display_name,
        .slug = slug,
        .biography = parsed.value.biography,
    }) catch |mutation_error| return managementError(request, mutation_error);
    return redirectToAuthors(request);
}

fn postUpdateAuthor(request: *RequestContext, _: Next) Error!void {
    const token = (try managerToken(request)) orelse return;
    const author_id = parseId(request.routeParam("id") orelse "") catch |failure| {
        web_logging.logDiagnostic(request, "warn", "management.request_rejected", "author identifier was rejected", .bad_request, failure, "invalid author id");
        return auth.respondText(request, "Invalid author form\n", .bad_request);
    };
    var parsed = form.extract(AuthorForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "management.request_rejected", "author form was rejected", .bad_request, failure, "invalid author form");
        return auth.respondText(request, "Invalid author form\n", .bad_request);
    };
    defer parsed.deinit(request.allocator());
    if (!try auth.requireCsrf(request, token, parsed.value.csrf_token)) return;

    const display_name = parsed.value.display_name;
    const slug = parsed.value.slug;
    _ = request.server.identity_service.updateAuthor(token, .{
        .author_id = author_id,
        .display_name = display_name,
        .slug = slug,
        .biography = parsed.value.biography orelse "",
    }) catch |mutation_error| return managementError(request, mutation_error);
    return redirectToAuthors(request);
}

fn postCreateAssignment(request: *RequestContext, _: Next) Error!void {
    const token = (try managerToken(request)) orelse return;
    var parsed = form.extract(AssignmentForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "management.request_rejected", "assignment form was rejected", .bad_request, failure, "invalid assignment form");
        return auth.respondText(request, "Invalid assignment form\n", .bad_request);
    };
    defer parsed.deinit(request.allocator());
    if (!try auth.requireCsrf(request, token, parsed.value.csrf_token)) return;

    const editor_user_id = validateId(parsed.value.editor_user_id) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "management.request_rejected", "editor identifier was rejected", .bad_request, failure, "invalid editor id");
        return auth.respondText(request, "Invalid assignment form\n", .bad_request);
    };
    const scope_type = parsed.value.scope_type;
    const scope_id = validateId(parsed.value.scope_id) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "management.request_rejected", "assignment scope identifier was rejected", .bad_request, failure, "invalid scope id");
        return auth.respondText(request, "Invalid assignment form\n", .bad_request);
    };
    const scope: domain.AssignmentScope = if (std.mem.eql(u8, scope_type, "author"))
        .{ .author = scope_id }
    else if (std.mem.eql(u8, scope_type, "document"))
        .{ .document = scope_id }
    else {
        web_logging.logDiagnostic(request, "warn", "management.request_rejected", "assignment scope type was rejected", .bad_request, error.InvalidAssignmentScope, "invalid assignment scope type");
        return auth.respondText(request, "Invalid assignment form\n", .bad_request);
    };

    _ = request.server.identity_service.createAssignment(token, .{
        .editor_user_id = editor_user_id,
        .scope = scope,
    }) catch |mutation_error| return managementError(request, mutation_error);
    return redirectToAuthors(request);
}

fn postRevokeAssignment(request: *RequestContext, _: Next) Error!void {
    const token = (try managerToken(request)) orelse return;
    const assignment_id = parseId(request.routeParam("id") orelse "") catch |failure| {
        web_logging.logDiagnostic(request, "warn", "management.request_rejected", "assignment identifier was rejected", .bad_request, failure, "invalid assignment id");
        return auth.respondText(request, "Invalid assignment form\n", .bad_request);
    };
    var parsed = form.extract(RevokeAssignmentForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "management.request_rejected", "assignment revoke form was rejected", .bad_request, failure, "invalid revoke form");
        return auth.respondText(request, "Invalid assignment form\n", .bad_request);
    };
    defer parsed.deinit(request.allocator());
    if (!try auth.requireCsrf(request, token, parsed.value.csrf_token)) return;
    const expected_revision = validateRevision(parsed.value.expected_revision) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "management.request_rejected", "assignment revision was rejected", .bad_request, failure, "invalid assignment revision");
        return auth.respondText(request, "Invalid assignment form\n", .bad_request);
    };
    _ = request.server.identity_service.revokeAssignment(token, .{
        .assignment_id = assignment_id,
        .expected_revision = expected_revision,
    }) catch |mutation_error| return managementError(request, mutation_error);
    return redirectToAuthors(request);
}

fn managerToken(request: *RequestContext) Error!?[]const u8 {
    if (!try auth.checkRequestOrigin(request)) return null;
    const token = auth.cookieValue(request, auth.session_cookie_name) orelse {
        try auth.redirectToLogin(request);
        return null;
    };
    const session = request.server.identity_service.authenticate(token) catch |failure| switch (failure) {
        error.InvalidSession => {
            web_logging.logDiagnostic(request, "info", "auth.session_rejected", "management session was rejected", .see_other, failure, "invalid session");
            try auth.redirectToLogin(request);
            return null;
        },
        else => {
            web_logging.logDiagnostic(request, "error", "auth.session_failed", "management session lookup failed", .internal_server_error, failure, null);
            try errors.respond(request, .internal_server_error);
            return null;
        },
    };
    if (auth.cookieValue(request, auth.csrf_cookie_name) == null) {
        web_logging.logDiagnostic(request, "warn", "auth.csrf_rejected", "management request had no CSRF cookie", .forbidden, null, "missing CSRF cookie");
        try errors.respond(request, .forbidden);
        return null;
    }
    request.authenticated_user_id = session.user_id;
    request.server.identity_service.requireCapability(token, .author_manage) catch |capability_error| switch (capability_error) {
        error.Forbidden => {
            web_logging.logDiagnostic(request, "warn", "management.authorization_rejected", "request lacks author management capability", .forbidden, capability_error, "missing author management capability");
            try errors.respond(request, .forbidden);
            return null;
        },
        else => {
            web_logging.logDiagnostic(request, "error", "management.authorization_failed", "author management authorization failed", .internal_server_error, capability_error, null);
            try errors.respond(request, .internal_server_error);
            return null;
        },
    };
    request.server.identity_service.requireCapability(token, .document_assign_editor) catch |capability_error| switch (capability_error) {
        error.Forbidden => {
            web_logging.logDiagnostic(request, "warn", "management.authorization_rejected", "request lacks editor assignment capability", .forbidden, capability_error, "missing editor assignment capability");
            try errors.respond(request, .forbidden);
            return null;
        },
        else => {
            web_logging.logDiagnostic(request, "error", "management.authorization_failed", "editor assignment authorization failed", .internal_server_error, capability_error, null);
            try errors.respond(request, .internal_server_error);
            return null;
        },
    };
    return token;
}

fn renderAuthors(request: *RequestContext, snapshot: management.Snapshot) Error!void {
    const csrf_token = auth.cookieValue(request, auth.csrf_cookie_name) orelse return error.InvalidCsrfToken;
    const body = try templates.pages.management.renderAlloc(request.allocator(), .{
        .csrf_token = csrf_token,
        .authors = snapshot.authors,
        .editors = snapshot.editors,
        .assignments = snapshot.assignments,
    });
    defer request.allocator().free(body);
    return auth.respond(request, body, "text/html; charset=utf-8", &.{.{ .name = "cache-control", .value = "no-store" }}, .ok);
}

fn redirectToAuthors(request: *RequestContext) Error!void {
    return auth.respond(request, &.{}, "text/plain; charset=utf-8", &.{
        .{ .name = "location", .value = "/admin/authors" },
        .{ .name = "cache-control", .value = "no-store" },
    }, .see_other);
}

fn parseId(value: []const u8) !i64 {
    const id = std.fmt.parseInt(i64, value, 10) catch return error.InvalidId;
    return validateId(id);
}

fn parseRevision(value: []const u8) !i64 {
    const revision = std.fmt.parseInt(i64, value, 10) catch return error.InvalidRevision;
    return validateRevision(revision);
}

fn validateId(value: i64) !i64 {
    if (value <= 0) return error.InvalidId;
    return value;
}

fn validateRevision(value: i64) !i64 {
    if (value < 0) return error.InvalidRevision;
    return value;
}

fn managementError(request: *RequestContext, failure: anyerror) Error!void {
    return switch (failure) {
        error.Forbidden => blk: {
            web_logging.logDiagnostic(request, "warn", "management.authorization_rejected", "management request was forbidden", .forbidden, failure, "insufficient capability");
            break :blk errors.respond(request, .forbidden);
        },
        error.AuthorNotFound,
        error.VersionNotFound,
        error.AssignmentNotFound,
        error.TargetNotEditor,
        error.DocumentNotFound,
        => blk: {
            web_logging.logDiagnostic(request, "warn", "management.request_rejected", "management target was not found", .not_found, failure, "management target not found");
            break :blk errors.respond(request, .not_found);
        },
        error.InvalidAuthor,
        error.InvalidDisplayName,
        error.InvalidAuthorSlug,
        error.InvalidBiography,
        error.InvalidEditor,
        error.InvalidAssignment,
        error.InvalidAssignmentScope,
        error.InvalidAssignmentRevision,
        error.ActiveAssignmentExists,
        error.StaleAssignment,
        error.ConstraintViolation,
        => blk: {
            web_logging.logDiagnostic(request, "warn", "management.request_rejected", "management request failed validation", .bad_request, failure, "invalid management request");
            break :blk auth.respondText(request, "Invalid management request\n", .bad_request);
        },
        else => blk: {
            web_logging.logDiagnostic(request, "error", "management.request_failed", "management operation failed", .internal_server_error, failure, null);
            break :blk errors.respond(request, .internal_server_error);
        },
    };
}

test "management routes keep mutations below the admin namespace" {
    try std.testing.expectEqual(@as(?usize, 0), routing.resolve(routes_table.asSlice(), .GET, "/admin/authors"));
    try std.testing.expectEqual(@as(?usize, 1), routing.resolve(routes_table.asSlice(), .POST, "/admin/authors"));
    try std.testing.expectEqual(@as(?usize, 2), routing.resolve(routes_table.asSlice(), .POST, "/admin/authors/4"));
    try std.testing.expectEqual(@as(?usize, 4), routing.resolve(routes_table.asSlice(), .POST, "/admin/assignments/7/revoke"));
    try std.testing.expectEqual(@as(?usize, null), routing.resolve(routes_table.asSlice(), .GET, "/admin/authors/4"));
}

test "assignment form revisions accept the initial zero revision" {
    try std.testing.expectEqual(@as(i64, 0), try parseRevision("0"));
    try std.testing.expectError(error.InvalidRevision, parseRevision("-1"));
}
