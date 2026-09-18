const std = @import("std");
const application = @import("../application/documents.zig");
const auth_identity = @import("../auth/identity.zig");
const domain = @import("../domain/document.zig");
const section_domain = @import("../domain/sections.zig");
const auth = @import("auth.zig");
const context = @import("context.zig");
const form = @import("form.zig");
const layer = @import("layer.zig");
const route = @import("router.zig");
const static_content = @import("static.zig");
const views = @import("editor_view.zig");
const tmpl = @import("tmpl");

const editor_head = tmpl.parse(@embedFile("templates/components/editor_head.html"), .{
    .parameters = .{ .page_title = {} },
});
const editor_section = tmpl.parse(@embedFile("templates/components/editor_section.html"), .{
    .parameters = .{
        .section = {},
        .csrf_token = {},
        .document_id = {},
        .version_id = {},
        .revision = {},
        .details_value = {},
        .oob = {},
    },
});
const editor_revision = tmpl.parse(@embedFile("templates/components/editor_revision.html"), .{
    .parameters = .{ .revision = {} },
});
const editor_template = tmpl.parse(@embedFile("templates/pages/editor.html"), .{
    .components = .{ .head = editor_head, .section_card = editor_section },
});
const document_list_template = tmpl.parse(@embedFile("templates/pages/document_list.html"), .{
    .components = .{ .head = editor_head },
});
const editor_base_css = @embedFile("styles/editor/base.css");
const editor_document_css = @embedFile("styles/editor/document.css");
const editor_sections_css = @embedFile("styles/editor/sections.css");
const editor_documents_css = @embedFile("styles/editor/documents.css");
const editor_responsive_css = @embedFile("styles/editor/responsive.css");
const local_actor: application.Actor = .local_operator;

pub const Handler = struct {
    pub fn routes() []const route.Route {
        return routes_table.asSlice();
    }
    pub fn router() route.Router {
        return routes_table.router();
    }
};

const routes_table = route.routes(.{
    .{ "GET /admin/editor", getEditor },
    .{ "POST /admin/editor/create", createDraft },
    .{ "POST /admin/editor/document", saveDocument },
    .{ "POST /admin/editor/section", mutateSection },
    .{ "GET /admin/editor-base.css", static_content.EmbeddedStatic.handler(
        editor_base_css,
        "text/css; charset=utf-8",
        .{ .status = .ok, .cache_control = "no-store" },
    ) },
    .{ "GET /admin/editor-document.css", static_content.EmbeddedStatic.handler(
        editor_document_css,
        "text/css; charset=utf-8",
        .{ .status = .ok, .cache_control = "no-store" },
    ) },
    .{ "GET /admin/editor-sections.css", static_content.EmbeddedStatic.handler(
        editor_sections_css,
        "text/css; charset=utf-8",
        .{ .status = .ok, .cache_control = "no-store" },
    ) },
    .{ "GET /admin/editor-documents.css", static_content.EmbeddedStatic.handler(
        editor_documents_css,
        "text/css; charset=utf-8",
        .{ .status = .ok, .cache_control = "no-store" },
    ) },
    .{ "GET /admin/editor-responsive.css", static_content.EmbeddedStatic.handler(
        editor_responsive_css,
        "text/css; charset=utf-8",
        .{ .status = .ok, .cache_control = "no-store" },
    ) },
});

fn getEditor(request: *context.RequestContext, _: layer.Next) anyerror!void {
    if (!try requireEditorCapability(request, .document_read_any)) return;
    const csrf = try csrfToken(request);
    const document_text = queryParam(request, "document") orelse return renderList(request, csrf, "", false);
    const document_id = parseId(document_text) catch return renderList(request, csrf, "Invalid document.", true);
    const version_id = request.server.document_service.mutableVersionForDocument(local_actor, document_id) catch |failure| {
        return renderList(request, csrf, failureMessage(failure), true);
    };
    return renderDocument(request, csrf, version_id, detailsOpen(request), previewId(request), "", false);
}

fn createDraft(request: *context.RequestContext, _: layer.Next) anyerror!void {
    if (!try requireEditorCapability(request, .document_create)) return;
    var values = form.read(request) catch return auth.respondText(request, "Invalid draft form\n", .bad_request);
    defer values.deinit(request.server.allocator);
    if (!try requireEditorCsrf(request, values.csrf_token)) return;
    const csrf = try csrfToken(request);
    const title = values.required("title") catch return renderList(request, csrf, "Enter a title.", true);
    const slug = values.required("slug") catch return renderList(request, csrf, "Enter a URL slug.", true);
    const draft = request.server.document_service.createDraft(local_actor, .{
        .document_type = .article,
        .title = title,
        .slug = slug,
        .description = null,
        .language = "en",
        .markdown = "",
    }) catch |failure| return renderList(request, csrf, failureMessage(failure), true);
    return renderDocument(request, csrf, draft.version_id, false, null, "Draft created.", false);
}

fn saveDocument(request: *context.RequestContext, _: layer.Next) anyerror!void {
    if (!try requireEditorCapability(request, .document_update_any)) return;
    var values = form.read(request) catch return auth.respondText(request, "Invalid document form\n", .bad_request);
    defer values.deinit(request.server.allocator);
    if (!try requireEditorCsrf(request, values.csrf_token)) return;
    const csrf = try csrfToken(request);
    const document_id = parseValue(values, "document_id") catch return auth.respondText(request, "Invalid document form\n", .bad_request);
    const version_id = parseValue(values, "version_id") catch return auth.respondText(request, "Invalid document form\n", .bad_request);
    const expected_revision = parseUnsigned(values, "expected_revision") catch return auth.respondText(request, "Invalid document form\n", .bad_request);
    const title = values.required("title") catch return renderDocumentById(request, csrf, document_id, "Enter a title.", true);
    const slug = values.required("slug") catch return renderDocumentById(request, csrf, document_id, "Enter a URL slug.", true);
    var loaded = request.server.document_service.loadDraft(local_actor, version_id) catch |failure| {
        return renderDocumentById(request, csrf, document_id, failureMessage(failure), true);
    };
    defer loaded.deinit();
    if (loaded.document.document_id != document_id) return renderDocumentById(request, csrf, document_id, "The draft identity did not match.", true);
    const draft_sections = try request.server.allocator.alloc(domain.DraftSection, loaded.document.sections.len);
    defer request.server.allocator.free(draft_sections);
    for (loaded.document.sections, 0..) |section, index| draft_sections[index] = section;
    const description_value = values.description orelse "";
    _ = request.server.document_service.saveDraft(local_actor, .{
        .document_id = document_id,
        .version_id = version_id,
        .expected_revision = expected_revision,
        .document_type = loaded.document.document_type,
        .title = title,
        .slug = slug,
        .description = if (description_value.len == 0) null else description_value,
        .language = loaded.document.language,
        .sections = draft_sections,
    }) catch |failure| return renderDocument(request, csrf, version_id, detailsOpen(request), null, failureMessage(failure), true);
    return renderDocument(request, csrf, version_id, detailsOpen(request), null, "Draft saved.", false);
}

fn mutateSection(request: *context.RequestContext, _: layer.Next) anyerror!void {
    if (!try requireEditorCapability(request, .document_update_any)) return;
    var values = form.read(request) catch return auth.respondText(request, "Invalid section form\n", .bad_request);
    defer values.deinit(request.server.allocator);
    if (!try requireEditorCsrf(request, values.csrf_token)) return;
    const csrf = try csrfToken(request);
    const document_id = parseValue(values, "document_id") catch return auth.respondText(request, "Invalid section form\n", .bad_request);
    const version_id = parseValue(values, "version_id") catch return renderDocumentById(request, csrf, document_id, "Invalid draft version.", true);
    const expected_revision = parseUnsigned(values, "expected_revision") catch return renderDocumentById(request, csrf, document_id, "Invalid draft revision.", true);
    const operation = values.required("operation") catch return renderDocumentById(request, csrf, document_id, "Invalid section operation.", true);

    if (std.mem.eql(u8, operation, "insert-text") or std.mem.eql(u8, operation, "insert-image")) {
        const payload: section_domain.Payload = if (std.mem.eql(u8, operation, "insert-text"))
            .{ .text = .{ .markdown = "" } }
        else
            .{ .image = .{ .asset = "placeholder.png", .alt = "Image placeholder", .caption = null, .display = .inline_display } };
        _ = request.server.document_service.insertSection(local_actor, .{
            .version_id = version_id,
            .position = sectionCount(request, version_id) catch 0,
            .expected_revision = expected_revision,
            .payload = payload,
        }) catch |failure| return renderDocument(request, csrf, version_id, false, null, failureMessage(failure), true);
        return renderDocument(request, csrf, version_id, false, null, "Section added.", false);
    }

    const section_id = parseValue(values, "section_id") catch return renderDocumentById(request, csrf, document_id, "Invalid section.", true);
    var loaded = request.server.document_service.loadDraft(local_actor, version_id) catch |failure| {
        return renderDocumentById(request, csrf, document_id, failureMessage(failure), true);
    };
    defer loaded.deinit();
    const index = findSection(loaded.document.sections, section_id) orelse return renderDocument(request, csrf, version_id, false, null, "Section not found.", true);

    if (std.mem.eql(u8, operation, "move-up") or std.mem.eql(u8, operation, "move-down")) {
        const target: u32 = if (std.mem.eql(u8, operation, "move-up"))
            @intCast(index -| 1)
        else
            @intCast(@min(index + 1, loaded.document.sections.len - 1));
        _ = request.server.document_service.moveSection(local_actor, .{ .version_id = version_id, .section_id = section_id, .position = target, .expected_revision = expected_revision }) catch |failure| return renderDocument(request, csrf, version_id, false, null, failureMessage(failure), true);
        return renderDocument(request, csrf, version_id, false, null, "Section order updated.", false);
    }
    if (std.mem.eql(u8, operation, "duplicate")) {
        _ = request.server.document_service.duplicateSection(local_actor, .{ .version_id = version_id, .section_id = section_id, .position = @intCast(index + 1), .expected_revision = expected_revision }) catch |failure| return renderDocument(request, csrf, version_id, false, null, failureMessage(failure), true);
        return renderDocument(request, csrf, version_id, false, null, "Section duplicated.", false);
    }
    if (std.mem.eql(u8, operation, "delete")) {
        _ = request.server.document_service.deleteSection(local_actor, .{ .version_id = version_id, .section_id = section_id, .expected_revision = expected_revision }) catch |failure| return renderDocument(request, csrf, version_id, false, null, failureMessage(failure), true);
        return renderDocument(request, csrf, version_id, false, null, "Section deleted.", false);
    }

    const payload = sectionPayload(values) catch |failure| return renderDocument(request, csrf, version_id, false, null, failureMessage(failure), true);
    _ = request.server.document_service.updateSection(local_actor, .{ .version_id = version_id, .section_id = section_id, .expected_revision = expected_revision, .payload = payload }) catch |failure| return renderDocument(request, csrf, version_id, false, null, failureMessage(failure), true);
    const show_preview = std.mem.eql(u8, operation, "preview");
    if (isHtmx(request)) return renderSection(request, csrf, version_id, section_id, if (show_preview) section_id else null) catch return renderDocument(request, csrf, version_id, false, null, "The section was saved, but could not be rendered.", true);
    return renderDocument(request, csrf, version_id, false, if (show_preview) section_id else null, if (show_preview) "Section saved and previewed." else "Section saved.", false);
}

fn renderList(request: *context.RequestContext, csrf: []const u8, notice: []const u8, is_error: bool) !void {
    const summaries = request.server.document_service.listDrafts(local_actor, request.server.allocator) catch |failure| return auth.respondText(request, failureMessage(failure), .internal_server_error);
    defer for (summaries) |*summary| summary.deinit(request.server.allocator);
    var arena = std.heap.ArenaAllocator.init(request.server.allocator);
    defer arena.deinit();
    const page = try views.list(arena.allocator(), csrf, summaries, notice, is_error);
    return respondPage(request, page);
}

fn renderDocumentById(request: *context.RequestContext, csrf: []const u8, document_id: i64, notice: []const u8, is_error: bool) !void {
    const version_id = request.server.document_service.mutableVersionForDocument(local_actor, document_id) catch return renderList(request, csrf, notice, is_error);
    return renderDocument(request, csrf, version_id, false, null, notice, is_error);
}

fn renderDocument(request: *context.RequestContext, csrf: []const u8, version_id: i64, details_open: bool, preview_id: ?i64, notice: []const u8, is_error: bool) !void {
    var loaded = request.server.document_service.loadDraft(local_actor, version_id) catch |failure| return renderList(request, csrf, failureMessage(failure), true);
    defer loaded.deinit();
    var arena = std.heap.ArenaAllocator.init(request.server.allocator);
    defer arena.deinit();
    const page = try views.editor(arena.allocator(), csrf, loaded.document, details_open, preview_id, notice, is_error);
    return respondPage(request, page);
}

fn renderSection(request: *context.RequestContext, csrf: []const u8, version_id: i64, section_id: i64, preview_id: ?i64) !void {
    var loaded = try request.server.document_service.loadDraft(local_actor, version_id);
    defer loaded.deinit();
    var arena = std.heap.ArenaAllocator.init(request.server.allocator);
    defer arena.deinit();
    const page = try views.editor(arena.allocator(), csrf, loaded.document, false, preview_id, "", false);
    var output: std.Io.Writer.Allocating = .init(request.server.allocator);
    defer output.deinit();
    try editor_revision.render(&output.writer, .{ .revision = page.revision });
    for (page.sections) |section| {
        const oob = if (section.id == section_id) "" else " hx-swap-oob=\"outerHTML\"";
        try editor_section.render(&output.writer, .{
            .section = section,
            .csrf_token = csrf,
            .document_id = page.document_id,
            .version_id = page.version_id,
            .revision = page.revision,
            .details_value = page.details_value,
            .oob = oob,
        });
    }
    const content = try output.toOwnedSlice();
    defer request.server.allocator.free(content);
    var target_buffer: [64]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "#section-{d}", .{section_id});
    const headers = [_]std.http.Header{
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "HX-Retarget", .value = target },
    };
    return auth.respond(request, content, "text/html; charset=utf-8", &headers, .ok);
}

fn requireEditorCapability(request: *context.RequestContext, capability: auth_identity.Capability) !bool {
    const token = auth.cookieValue(request, auth.session_cookie_name) orelse {
        try auth.respondText(request, "Authentication required\n", .unauthorized);
        return false;
    };
    request.server.identity_service.requireCapability(token, capability) catch |failure| switch (failure) {
        error.Forbidden => {
            try auth.respondText(request, "Forbidden\n", .forbidden);
            return false;
        },
        else => return failure,
    };
    return true;
}

fn respondPage(request: *context.RequestContext, page: views.Page) !void {
    const content = try switch (page.kind) {
        .editor => editor_template.renderAlloc(request.server.allocator, page),
        .document_list => document_list_template.renderAlloc(request.server.allocator, page),
    };
    defer request.server.allocator.free(content);
    return auth.respond(request, content, "text/html; charset=utf-8", &.{.{ .name = "cache-control", .value = "no-store" }}, .ok);
}

fn sectionPayload(values: form.Values) !section_domain.Payload {
    const kind = values.required("kind") catch return error.InvalidSectionKind;
    if (std.mem.eql(u8, kind, "text")) return .{ .text = .{ .markdown = values.required("markdown") catch return error.InvalidMarkdown } };
    if (!std.mem.eql(u8, kind, "image")) return error.InvalidSectionKind;
    const display_text = values.display orelse "inline";
    return .{ .image = .{
        .asset = values.required("asset") catch return error.InvalidAssetName,
        .alt = values.required("alt") catch return error.InvalidAltText,
        .caption = if (values.caption) |caption| if (caption.len == 0) null else caption else null,
        .display = try section_domain.ImageDisplay.parse(display_text),
    } };
}

fn sectionCount(request: *context.RequestContext, version_id: i64) !u32 {
    var loaded = try request.server.document_service.loadDraft(local_actor, version_id);
    defer loaded.deinit();
    return std.math.cast(u32, loaded.document.sections.len) orelse error.SectionLimitExceeded;
}

fn findSection(sections: []const domain.DraftSection, id: i64) ?usize {
    for (sections, 0..) |section, index| if (section.id == id) return index;
    return null;
}

fn requireEditorCsrf(request: *context.RequestContext, token: ?[]const u8) !bool {
    const session = auth.cookieValue(request, auth.session_cookie_name) orelse return false;
    return auth.requireCsrf(request, session, token);
}

fn csrfToken(request: *context.RequestContext) ![]const u8 {
    return auth.cookieValue(request, auth.csrf_cookie_name) orelse {
        try auth.respondText(request, "CSRF validation failed\n", .forbidden);
        return error.ResponseAlreadySent;
    };
}

fn parseValue(values: form.Values, comptime field: []const u8) !i64 {
    return std.fmt.parseInt(i64, try values.required(field), 10) catch error.InvalidForm;
}

fn parseUnsigned(values: form.Values, comptime field: []const u8) !u64 {
    return std.fmt.parseInt(u64, try values.required(field), 10) catch error.InvalidForm;
}

fn parseId(value: []const u8) !i64 {
    const id = std.fmt.parseInt(i64, value, 10) catch return error.InvalidId;
    if (id <= 0) return error.InvalidId;
    return id;
}

fn detailsOpen(request: *const context.RequestContext) bool {
    return std.mem.eql(u8, queryParam(request, "details") orelse "0", "1");
}

fn previewId(request: *const context.RequestContext) ?i64 {
    const value = queryParam(request, "preview") orelse return null;
    return parseId(value) catch null;
}

fn queryParam(request: *const context.RequestContext, name: []const u8) ?[]const u8 {
    const query_start = std.mem.indexOfScalar(u8, request.request.head.target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, request.request.head.target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const separator = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..separator], name)) return pair[separator + 1 ..];
    }
    return null;
}

fn isHtmx(request: *const context.RequestContext) bool {
    return auth.headerValue(request, "hx-request") != null;
}

fn failureMessage(failure: anyerror) []const u8 {
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

test "editor routes expose page, mutation, and embedded stylesheet endpoints" {
    const routes = Handler.routes();
    try std.testing.expectEqual(@as(?usize, 0), route.resolve(routes, .GET, "/admin/editor?document=1"));
    try std.testing.expectEqual(@as(?usize, 1), route.resolve(routes, .POST, "/admin/editor/create"));
    try std.testing.expectEqual(@as(?usize, 2), route.resolve(routes, .POST, "/admin/editor/document"));
    try std.testing.expectEqual(@as(?usize, 3), route.resolve(routes, .POST, "/admin/editor/section"));
    try std.testing.expectEqual(@as(?usize, 4), route.resolve(routes, .GET, "/admin/editor-base.css"));
    try std.testing.expectEqual(@as(?usize, 5), route.resolve(routes, .GET, "/admin/editor-document.css"));
    try std.testing.expectEqual(@as(?usize, 6), route.resolve(routes, .GET, "/admin/editor-sections.css"));
    try std.testing.expectEqual(@as(?usize, 7), route.resolve(routes, .GET, "/admin/editor-documents.css"));
    try std.testing.expectEqual(@as(?usize, 8), route.resolve(routes, .GET, "/admin/editor-responsive.css"));
    try std.testing.expectEqual(@as(?usize, null), route.resolve(routes, .POST, "/admin/editor"));
}
