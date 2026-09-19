const std = @import("std");
const domain = @import("../domain/identity.zig");
const auth = @import("auth.zig");
const context = @import("context.zig");
const escape = @import("tmpl").escape;
const form = @import("form.zig");
const layer = @import("layer.zig");
const management = @import("../application/identity_management.zig");
const routing = @import("router.zig");

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
    var snapshot = request.server.identity_management_service.list(token) catch |list_error| {
        return managementError(request, list_error);
    };
    defer snapshot.deinit();
    return renderAuthors(request, snapshot);
}

fn postCreateAuthor(request: *RequestContext, _: Next) Error!void {
    const token = (try managerToken(request)) orelse return;
    var parsed = form.extract(AuthorForm, request) catch {
        return auth.respondText(request, "Invalid author form\n", .bad_request);
    };
    defer parsed.deinit(request.server.allocator);
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
    const author_id = parseId(request.routeParam("id") orelse "") catch {
        return auth.respondText(request, "Invalid author form\n", .bad_request);
    };
    var parsed = form.extract(AuthorForm, request) catch {
        return auth.respondText(request, "Invalid author form\n", .bad_request);
    };
    defer parsed.deinit(request.server.allocator);
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
    var parsed = form.extract(AssignmentForm, request) catch {
        return auth.respondText(request, "Invalid assignment form\n", .bad_request);
    };
    defer parsed.deinit(request.server.allocator);
    if (!try auth.requireCsrf(request, token, parsed.value.csrf_token)) return;

    const editor_user_id = validateId(parsed.value.editor_user_id) catch
        return auth.respondText(request, "Invalid assignment form\n", .bad_request);
    const scope_type = parsed.value.scope_type;
    const scope_id = validateId(parsed.value.scope_id) catch
        return auth.respondText(request, "Invalid assignment form\n", .bad_request);
    const scope: domain.AssignmentScope = if (std.mem.eql(u8, scope_type, "author"))
        .{ .author = scope_id }
    else if (std.mem.eql(u8, scope_type, "document"))
        .{ .document = scope_id }
    else
        return auth.respondText(request, "Invalid assignment form\n", .bad_request);

    _ = request.server.identity_service.createAssignment(token, .{
        .editor_user_id = editor_user_id,
        .scope = scope,
    }) catch |mutation_error| return managementError(request, mutation_error);
    return redirectToAuthors(request);
}

fn postRevokeAssignment(request: *RequestContext, _: Next) Error!void {
    const token = (try managerToken(request)) orelse return;
    const assignment_id = parseId(request.routeParam("id") orelse "") catch {
        return auth.respondText(request, "Invalid assignment form\n", .bad_request);
    };
    var parsed = form.extract(RevokeAssignmentForm, request) catch {
        return auth.respondText(request, "Invalid assignment form\n", .bad_request);
    };
    defer parsed.deinit(request.server.allocator);
    if (!try auth.requireCsrf(request, token, parsed.value.csrf_token)) return;
    const expected_revision = validateRevision(parsed.value.expected_revision) catch
        return auth.respondText(request, "Invalid assignment form\n", .bad_request);
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
    const session = request.server.identity_service.authenticate(token) catch {
        try auth.redirectToLogin(request);
        return null;
    };
    if (auth.cookieValue(request, auth.csrf_cookie_name) == null) {
        try auth.respondText(request, "CSRF validation failed\n", .forbidden);
        return null;
    }
    request.authenticated_user_id = session.user_id;
    request.server.identity_service.requireCapability(token, .author_manage) catch |capability_error| switch (capability_error) {
        error.Forbidden => {
            try auth.respondText(request, "Forbidden\n", .forbidden);
            return null;
        },
        else => return capability_error,
    };
    request.server.identity_service.requireCapability(token, .document_assign_editor) catch |capability_error| switch (capability_error) {
        error.Forbidden => {
            try auth.respondText(request, "Forbidden\n", .forbidden);
            return null;
        },
        else => return capability_error,
    };
    return token;
}

fn renderAuthors(request: *RequestContext, snapshot: management.Snapshot) Error!void {
    var output: std.Io.Writer.Allocating = .init(request.server.allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll(
        \\<!doctype html><html lang="en"><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>Authors and assignments</title></head><body><main>
        \\<h1>Authors and assignments</h1>
        \\<p><a href="/admin/editor">Editor</a> | <a href="/admin/password">Change password</a></p>
        \\<h2>Add author</h2><form method="post" action="/admin/authors">
        \\<input type="hidden" name="csrf_token" value="
    );
    try writeCsrf(writer, request);
    try writer.writeAll(
        \\"><label>Name <input name="display_name" required></label>
        \\<label>Slug <input name="slug" required></label>
        \\<label>Biography <textarea name="biography"></textarea></label>
        \\<button type="submit">Add author</button></form>
        \\<h2>Authors</h2><ul>
    );
    for (snapshot.authors) |author| {
        try writer.writeAll("<li><form method=\"post\" action=\"/admin/authors/");
        try writer.print("{}", .{author.id});
        try writer.writeAll("\"><input type=\"hidden\" name=\"csrf_token\" value=\"");
        try writeCsrf(writer, request);
        try writer.writeAll("\"><label>Name <input name=\"display_name\" value=\"");
        try escape.write(writer, author.display_name.data, true);
        try writer.writeAll("\" required></label><label>Slug <input name=\"slug\" value=\"");
        try escape.write(writer, author.slug.data, true);
        try writer.writeAll("\" required></label><label>Biography <textarea name=\"biography\">");
        try escape.write(writer, author.biography.data, true);
        try writer.writeAll("</textarea></label><button type=\"submit\">Save</button></form></li>");
    }
    try writer.writeAll("</ul><h2>Assignments</h2><ul>");
    for (snapshot.assignments) |assignment| {
        try writer.writeAll("<li>");
        try escape.write(writer, assignment.editor_display_name.data, true);
        try writer.writeAll(" - ");
        try escape.write(writer, assignment.scope_kind.data, true);
        try writer.writeAll(" ");
        try escape.write(writer, assignment.scope_name.data, true);
        try writer.writeAll(" <form method=\"post\" style=\"display:inline\" action=\"/admin/assignments/");
        try writer.print("{}/revoke\"><input type=\"hidden\" name=\"csrf_token\" value=\"", .{assignment.id});
        try writeCsrf(writer, request);
        try writer.print("\"><input type=\"hidden\" name=\"expected_revision\" value=\"{}\"><button type=\"submit\">Revoke</button></form></li>", .{assignment.revision_number});
    }
    try writer.writeAll(
        \\</ul><h2>Assign editor</h2><form method="post" action="/admin/assignments">
        \\<input type="hidden" name="csrf_token" value="
    );
    try writeCsrf(writer, request);
    try writer.writeAll("\"><label>Editor <select name=\"editor_user_id\" required>");
    for (snapshot.editors) |editor| {
        try writer.print("<option value=\"{}\">", .{editor.id});
        try escape.write(writer, editor.display_name.data, true);
        try writer.writeAll("</option>");
    }
    try writer.writeAll(
        \\</select></label><label>Scope <select name="scope_type">
        \\<option value="author">Author</option><option value="document">Document</option>
        \\</select></label><label>Scope ID <input name="scope_id" inputmode="numeric" required></label>
        \\<button type="submit">Assign</button></form></main></body></html>
    );
    const body = try output.toOwnedSlice();
    defer request.server.allocator.free(body);
    return auth.respond(request, body, "text/html; charset=utf-8", &.{.{ .name = "cache-control", .value = "no-store" }}, .ok);
}

fn writeCsrf(writer: *std.Io.Writer, request: *const RequestContext) !void {
    const token = auth.cookieValue(request, auth.csrf_cookie_name) orelse return error.InvalidCsrfToken;
    try escape.write(writer, token, true);
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
        error.Forbidden => auth.respondText(request, "Forbidden\n", .forbidden),
        error.AuthorNotFound,
        error.VersionNotFound,
        error.AssignmentNotFound,
        error.TargetNotEditor,
        error.DocumentNotFound,
        => auth.respondText(request, "Not found\n", .not_found),
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
        => auth.respondText(request, "Invalid management request\n", .bad_request),
        else => auth.respondText(request, "Management operation failed\n", .internal_server_error),
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
