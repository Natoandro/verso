const std = @import("std");
const application = @import("../application/documents.zig");
const domain = @import("../domain/document.zig");
const section_domain = @import("../domain/sections.zig");
const auth = @import("auth.zig");
const context = @import("context.zig");
const errors = @import("errors.zig");
const templates = @import("templates/root.zig");
const views = @import("editor_view.zig");
const web_logging = @import("logging.zig");

pub fn currentActor(request: *const context.RequestContext) !application.Actor {
    const user_id = request.authenticated_user_id orelse {
        web_logging.logDiagnostic(request, "error", "auth.session_failed", "editor request had no authenticated actor", .internal_server_error, error.InvalidSession, null);
        return error.InvalidSession;
    };
    return .{ .user = user_id };
}

pub fn editorFailure(request: *context.RequestContext, failure: anyerror) !void {
    return switch (failure) {
        error.Forbidden => blk: {
            web_logging.logDiagnostic(request, "warn", "editor.authorization_rejected", "editor request was forbidden", .forbidden, failure, "insufficient capability");
            break :blk auth.respondText(request, "Forbidden\n", .forbidden);
        },
        else => blk: {
            web_logging.logDiagnostic(request, "error", "editor.request_failed", "editor operation failed", .internal_server_error, failure, null);
            break :blk auth.respondText(request, failureMessage(failure), .internal_server_error);
        },
    };
}

pub fn respondPage(request: *context.RequestContext, page: views.Page) !void {
    return respondPageWithHeaders(request, page, &.{});
}

pub fn respondPageWithHeaders(request: *context.RequestContext, page: views.Page, extra_headers: []const std.http.Header) !void {
    const content = switch (page.kind) {
        .editor => templates.pages.editor.renderAlloc(request.allocator(), page),
        .document_list => templates.pages.document_list.renderAlloc(request.allocator(), page),
    } catch |failure| {
        web_logging.logDiagnostic(request, "error", "editor.render_failed", "editor page template rendering failed", .internal_server_error, failure, null);
        return failure;
    };
    defer request.allocator().free(content);
    if (extra_headers.len > 3) {
        web_logging.logDiagnostic(request, "error", "http.response_failed", "editor response contained too many headers", .internal_server_error, error.TooManyResponseHeaders, null);
        return error.TooManyResponseHeaders;
    }
    var headers: [4]std.http.Header = undefined;
    headers[0] = .{ .name = "cache-control", .value = "no-store" };
    for (extra_headers, 0..) |header, index| headers[index + 1] = header;
    return auth.respond(request, content, "text/html; charset=utf-8", headers[0 .. extra_headers.len + 1], .ok);
}

pub fn sectionPayload(values: anytype) !section_domain.Payload {
    const kind = values.kind orelse return error.InvalidSectionKind;
    if (std.mem.eql(u8, kind, "text")) return .{ .text = .{ .markdown = values.markdown orelse return error.InvalidMarkdown } };
    if (!std.mem.eql(u8, kind, "image")) return error.InvalidSectionKind;
    const display_text = values.display orelse "inline";
    return .{ .image = .{
        .asset = values.asset orelse return error.InvalidAssetName,
        .alt = values.alt orelse return error.InvalidAltText,
        .caption = if (values.caption) |caption| if (caption.len == 0) null else caption else null,
        .display = try section_domain.ImageDisplay.parse(display_text),
    } };
}

pub fn sectionCount(request: *context.RequestContext, version_id: i64) !u32 {
    const actor = try currentActor(request);
    var loaded = try request.server.document_service.loadDraftWithAllocator(request.allocator(), actor, version_id);
    defer loaded.deinit();
    return std.math.cast(u32, loaded.document.sections.len) orelse error.SectionLimitExceeded;
}

pub fn findSection(sections: []const domain.DraftSection, id: i64) ?usize {
    for (sections, 0..) |section, index| if (section.id == id) return index;
    return null;
}

pub fn requireEditorCsrf(request: *context.RequestContext, token: ?[]const u8) !bool {
    const session = auth.cookieValue(request, auth.session_cookie_name) orelse {
        web_logging.logDiagnostic(request, "warn", "auth.session_rejected", "editor request had no session cookie", .unauthorized, null, "missing session cookie");
        return false;
    };
    return auth.requireCsrf(request, session, token);
}

pub fn csrfToken(request: *context.RequestContext) ![]const u8 {
    return auth.cookieValue(request, auth.csrf_cookie_name) orelse {
        web_logging.logDiagnostic(request, "warn", "auth.csrf_rejected", "editor request had no CSRF cookie", .forbidden, null, "missing CSRF cookie");
        try errors.respond(request, .forbidden);
        return error.ResponseAlreadySent;
    };
}

pub fn parseId(value: []const u8) !i64 {
    const id = std.fmt.parseInt(i64, value, 10) catch return error.InvalidId;
    if (id <= 0) return error.InvalidId;
    return id;
}

pub fn detailsOpen(request: *const context.RequestContext) bool {
    return std.mem.eql(u8, queryParam(request, "details") orelse "0", "1");
}

pub fn titleEditing(request: *const context.RequestContext) bool {
    return std.mem.eql(u8, queryParam(request, "title") orelse "0", "1");
}

pub fn editId(request: *const context.RequestContext) ?i64 {
    const value = queryParam(request, "edit") orelse return null;
    return parseId(value) catch null;
}

pub fn queryParam(request: *const context.RequestContext, name: []const u8) ?[]const u8 {
    const target = request.requestTarget();
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const separator = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..separator], name)) return pair[separator + 1 ..];
    }
    return null;
}

pub fn failureMessage(failure: anyerror) []const u8 {
    return switch (failure) {
        error.StaleRevision => "This draft changed in another tab. Reloaded the current revision without overwriting it.",
        error.InvalidTitle => "Enter a non-empty document title.",
        error.InvalidSlug => "Use a URL slug containing only letters, numbers, hyphens, or underscores.",
        error.InvalidAssetName => "Enter a valid asset name.",
        error.InvalidAltText => "Image alt text is required.",
        error.InvalidPosition => "That section position is no longer available.",
        error.MutableDraftExists => "This document already has an editable draft.",
        error.VersionNotEditable => "Only editable drafts can be changed.",
        error.DraftNotFound, error.VersionNotFound, error.DocumentNotFound => "That draft could not be found.",
        error.Forbidden => "You are not allowed to edit this draft.",
        else => "The draft could not be updated. Check the fields and try again.",
    };
}
