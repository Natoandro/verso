const std = @import("std");
const application = @import("../application/documents.zig");
const domain = @import("../domain/document.zig");
const section_domain = @import("../domain/sections.zig");
const auth = @import("auth.zig");
const context = @import("context.zig");
const errors = @import("errors.zig");
const form = @import("form.zig");
const layer = @import("layer.zig");
const route = @import("router.zig");
const static_content = @import("static.zig");
const templates = @import("templates/root.zig");
const views = @import("editor_view.zig");
const web_logging = @import("logging.zig");

const theme_css = @embedFile("styles/theme.css");
const editor_base_css = @embedFile("styles/editor/base.css");
const editor_document_css = @embedFile("styles/editor/document.css");
const editor_sections_css = @embedFile("styles/editor/sections.css");
const editor_documents_css = @embedFile("styles/editor/documents.css");
const editor_responsive_css = @embedFile("styles/editor/responsive.css");
const CreateDraftForm = struct {
    csrf_token: ?[]const u8,
    title: []const u8,
    slug: []const u8,
};

const SaveDocumentForm = struct {
    csrf_token: ?[]const u8,
    document_id: i64,
    version_id: i64,
    expected_revision: u64,
    title: []const u8,
    slug: []const u8,
    description: ?[]const u8,
};

const SectionForm = struct {
    csrf_token: ?[]const u8,
    document_id: i64,
    version_id: i64,
    expected_revision: u64,
    section_id: ?i64,
    operation: []const u8,
    kind: ?[]const u8,
    markdown: ?[]const u8,
    asset: ?[]const u8,
    alt: ?[]const u8,
    caption: ?[]const u8,
    display: ?[]const u8,
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
    .{ "GET /admin/editor", getEditor },
    .{ "POST /admin/editor/create", createDraft },
    .{ "POST /admin/editor/document", saveDocument },
    .{ "POST /admin/editor/section", mutateSection },
    .{ "GET /admin/theme.css", static_content.EmbeddedStatic.handler(
        theme_css,
        "text/css; charset=utf-8",
        .{ .status = .ok, .cache_control = "no-store" },
    ) },
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
    const actor = try currentActor(request);
    const csrf = try csrfToken(request);
    const document_text = queryParam(request, "document") orelse return renderList(request, csrf, "", false);
    const document_id = parseId(document_text) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.request_rejected", "document identifier was rejected", .ok, failure, "invalid document id");
        return renderList(request, csrf, "Invalid document.", true);
    };
    const version_id = request.server.document_service.mutableVersionForDocument(actor, document_id) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.load_rejected", "editable document could not be selected", .ok, failure, "document lookup failed");
        return renderList(request, csrf, failureMessage(failure), true);
    };
    return renderDocument(request, csrf, version_id, detailsOpen(request), titleEditing(request), previewId(request), "", false);
}

fn createDraft(request: *context.RequestContext, _: layer.Next) anyerror!void {
    const actor = try currentActor(request);
    var parsed = form.extract(CreateDraftForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.request_rejected", "draft form was rejected", .bad_request, failure, "invalid draft form");
        return auth.respondText(request, "Invalid draft form\n", .bad_request);
    };
    defer parsed.deinit(request.allocator());
    if (!try requireEditorCsrf(request, parsed.value.csrf_token)) return;
    const csrf = try csrfToken(request);
    const draft = request.server.document_service.createDraftWithAllocator(request.allocator(), actor, .{
        .document_type = .article,
        .title = parsed.value.title,
        .slug = parsed.value.slug,
        .description = null,
        .language = "en",
        .markdown = "",
    }) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.draft_failed", "draft creation failed", .ok, failure, null);
        return renderList(request, csrf, failureMessage(failure), true);
    };
    return renderDocument(request, csrf, draft.version_id, false, false, null, "Draft created.", false);
}

fn saveDocument(request: *context.RequestContext, _: layer.Next) anyerror!void {
    const actor = try currentActor(request);
    var parsed = form.extract(SaveDocumentForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.request_rejected", "document form was rejected", .bad_request, failure, "invalid document form");
        return auth.respondText(request, "Invalid document form\n", .bad_request);
    };
    defer parsed.deinit(request.allocator());
    if (!try requireEditorCsrf(request, parsed.value.csrf_token)) return;
    const csrf = try csrfToken(request);
    const document_id = parsed.value.document_id;
    const version_id = parsed.value.version_id;
    const expected_revision = parsed.value.expected_revision;
    var loaded = request.server.document_service.loadDraftWithAllocator(request.allocator(), actor, version_id) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.load_failed", "draft could not be loaded for saving", .ok, failure, null);
        return renderDocumentById(request, csrf, document_id, failureMessage(failure), true);
    };
    defer loaded.deinit();
    if (loaded.document.document_id != document_id) {
        web_logging.logDiagnostic(request, "error", "editor.load_failed", "draft identity did not match request", .ok, error.InvalidStoredDocument, null);
        return renderDocumentById(request, csrf, document_id, "The draft identity did not match.", true);
    }
    const draft_sections = try request.allocator().alloc(domain.DraftSection, loaded.document.sections.len);
    for (loaded.document.sections, 0..) |section, index| draft_sections[index] = section;
    const description_value = parsed.value.description orelse "";
    _ = request.server.document_service.saveDraftWithAllocator(request.allocator(), actor, .{
        .document_id = document_id,
        .version_id = version_id,
        .expected_revision = expected_revision,
        .document_type = loaded.document.document_type,
        .title = parsed.value.title,
        .slug = parsed.value.slug,
        .description = if (description_value.len == 0) null else description_value,
        .language = loaded.document.language,
        .sections = draft_sections,
    }) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.document_save_failed", "draft save failed", .ok, failure, null);
        return renderDocument(request, csrf, version_id, detailsOpen(request), titleEditing(request), null, failureMessage(failure), true);
    };
    return renderDocument(request, csrf, version_id, detailsOpen(request), false, null, "Draft saved.", false);
}

fn mutateSection(request: *context.RequestContext, _: layer.Next) anyerror!void {
    const actor = try currentActor(request);
    var parsed = form.extract(SectionForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.request_rejected", "section form was rejected", .bad_request, failure, "invalid section form");
        return auth.respondText(request, "Invalid section form\n", .bad_request);
    };
    defer parsed.deinit(request.allocator());
    if (!try requireEditorCsrf(request, parsed.value.csrf_token)) return;
    const csrf = try csrfToken(request);
    const document_id = parsed.value.document_id;
    const version_id = parsed.value.version_id;
    const expected_revision = parsed.value.expected_revision;
    const operation = parsed.value.operation;

    if (std.mem.eql(u8, operation, "insert-text") or std.mem.eql(u8, operation, "insert-image")) {
        const payload: section_domain.Payload = if (std.mem.eql(u8, operation, "insert-text"))
            .{ .text = .{ .markdown = "" } }
        else
            .{ .image = .{ .asset = "placeholder.png", .alt = "Image placeholder", .caption = null, .display = .inline_display } };
        const position = sectionCount(request, version_id) catch |failure| {
            web_logging.logDiagnostic(request, "error", "editor.section_load_failed", "could not determine section insertion position", .internal_server_error, failure, null);
            return renderDocument(request, csrf, version_id, false, false, null, "The section could not be added.", true);
        };
        _ = request.server.document_service.insertSectionWithAllocator(request.allocator(), actor, .{
            .version_id = version_id,
            .position = position,
            .expected_revision = expected_revision,
            .payload = payload,
        }) catch |failure| {
            web_logging.logDiagnostic(request, "warn", "editor.section_mutation_failed", "section insertion failed", .ok, failure, null);
            return renderDocument(request, csrf, version_id, false, false, null, failureMessage(failure), true);
        };
        return renderDocument(request, csrf, version_id, false, false, null, "Section added.", false);
    }

    const section_id = parsed.value.section_id orelse {
        web_logging.logDiagnostic(request, "warn", "editor.request_rejected", "section request had no section identifier", .ok, error.InvalidSectionId, "missing section id");
        return renderDocumentById(request, csrf, document_id, "Invalid section.", true);
    };
    if (section_id <= 0) {
        web_logging.logDiagnostic(request, "warn", "editor.request_rejected", "section identifier was rejected", .ok, error.InvalidSectionId, "invalid section id");
        return renderDocumentById(request, csrf, document_id, "Invalid section.", true);
    }
    var loaded = request.server.document_service.loadDraftWithAllocator(request.allocator(), actor, version_id) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.load_failed", "draft could not be loaded for section mutation", .ok, failure, null);
        return renderDocumentById(request, csrf, document_id, failureMessage(failure), true);
    };
    defer loaded.deinit();
    const index = findSection(loaded.document.sections, section_id) orelse {
        web_logging.logDiagnostic(request, "warn", "editor.request_rejected", "section was not found", .ok, error.SectionNotFound, "section not found");
        return renderDocument(request, csrf, version_id, false, false, null, "Section not found.", true);
    };

    if (std.mem.eql(u8, operation, "move-up") or std.mem.eql(u8, operation, "move-down")) {
        const target: u32 = if (std.mem.eql(u8, operation, "move-up"))
            @intCast(index -| 1)
        else
            @intCast(@min(index + 1, loaded.document.sections.len - 1));
        _ = request.server.document_service.moveSection(actor, .{ .version_id = version_id, .section_id = section_id, .position = target, .expected_revision = expected_revision }) catch |failure| {
            web_logging.logDiagnostic(request, "warn", "editor.section_mutation_failed", "section move failed", .ok, failure, null);
            return renderDocument(request, csrf, version_id, false, false, null, failureMessage(failure), true);
        };
        return renderDocument(request, csrf, version_id, false, false, null, "Section order updated.", false);
    }
    if (std.mem.eql(u8, operation, "duplicate")) {
        _ = request.server.document_service.duplicateSection(actor, .{ .version_id = version_id, .section_id = section_id, .position = @intCast(index + 1), .expected_revision = expected_revision }) catch |failure| {
            web_logging.logDiagnostic(request, "warn", "editor.section_mutation_failed", "section duplication failed", .ok, failure, null);
            return renderDocument(request, csrf, version_id, false, false, null, failureMessage(failure), true);
        };
        return renderDocument(request, csrf, version_id, false, false, null, "Section duplicated.", false);
    }
    if (std.mem.eql(u8, operation, "delete")) {
        _ = request.server.document_service.deleteSection(actor, .{ .version_id = version_id, .section_id = section_id, .expected_revision = expected_revision }) catch |failure| {
            web_logging.logDiagnostic(request, "warn", "editor.section_mutation_failed", "section deletion failed", .ok, failure, null);
            return renderDocument(request, csrf, version_id, false, false, null, failureMessage(failure), true);
        };
        return renderDocument(request, csrf, version_id, false, false, null, "Section deleted.", false);
    }

    const payload = sectionPayload(parsed.value) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.request_rejected", "section payload was rejected", .ok, failure, "invalid section payload");
        return renderDocument(request, csrf, version_id, false, false, null, failureMessage(failure), true);
    };
    _ = request.server.document_service.updateSectionWithAllocator(request.allocator(), actor, .{ .version_id = version_id, .section_id = section_id, .expected_revision = expected_revision, .payload = payload }) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.section_mutation_failed", "section update failed", .ok, failure, null);
        return renderDocument(request, csrf, version_id, false, false, null, failureMessage(failure), true);
    };
    const show_preview = std.mem.eql(u8, operation, "preview");
    return renderDocument(request, csrf, version_id, false, false, if (show_preview) section_id else null, if (show_preview) "Section saved and previewed." else "Section saved.", false);
}

fn renderList(request: *context.RequestContext, csrf: []const u8, notice: []const u8, is_error: bool) !void {
    const actor = try currentActor(request);
    const summaries = request.server.document_service.listDrafts(actor, request.allocator()) catch |failure| return editorFailure(request, failure);
    defer for (summaries) |*summary| summary.deinit(request.allocator());
    const page = views.list(request.allocator(), csrf, summaries, notice, is_error) catch |failure| {
        web_logging.logDiagnostic(request, "error", "editor.render_failed", "editor list rendering failed", .internal_server_error, failure, null);
        return failure;
    };
    return respondPage(request, page);
}

fn renderDocumentById(request: *context.RequestContext, csrf: []const u8, document_id: i64, notice: []const u8, is_error: bool) !void {
    const actor = try currentActor(request);
    const version_id = request.server.document_service.mutableVersionForDocument(actor, document_id) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.load_failed", "document draft lookup failed", .ok, failure, null);
        return renderList(request, csrf, notice, is_error);
    };
    return renderDocument(request, csrf, version_id, false, false, null, notice, is_error);
}

fn renderDocument(request: *context.RequestContext, csrf: []const u8, version_id: i64, details_open: bool, title_editing: bool, preview_id: ?i64, notice: []const u8, is_error: bool) !void {
    const actor = try currentActor(request);
    var loaded = request.server.document_service.loadDraftWithAllocator(request.allocator(), actor, version_id) catch |failure| return editorFailure(request, failure);
    defer loaded.deinit();
    const page = views.editor(request.allocator(), csrf, loaded.document, details_open, title_editing, preview_id, notice, is_error) catch |failure| {
        web_logging.logDiagnostic(request, "error", "editor.render_failed", "editor document rendering failed", .internal_server_error, failure, null);
        return failure;
    };
    return respondPage(request, page);
}

fn currentActor(request: *const context.RequestContext) !application.Actor {
    const user_id = request.authenticated_user_id orelse {
        web_logging.logDiagnostic(request, "error", "auth.session_failed", "editor request had no authenticated actor", .internal_server_error, error.InvalidSession, null);
        return error.InvalidSession;
    };
    return .{ .user = user_id };
}

fn editorFailure(request: *context.RequestContext, failure: anyerror) !void {
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

fn respondPage(request: *context.RequestContext, page: views.Page) !void {
    const content = switch (page.kind) {
        .editor => templates.pages.editor.renderAlloc(request.allocator(), page),
        .document_list => templates.pages.document_list.renderAlloc(request.allocator(), page),
    } catch |failure| {
        web_logging.logDiagnostic(request, "error", "editor.render_failed", "editor page template rendering failed", .internal_server_error, failure, null);
        return failure;
    };
    defer request.allocator().free(content);
    return auth.respond(request, content, "text/html; charset=utf-8", &.{.{ .name = "cache-control", .value = "no-store" }}, .ok);
}

fn sectionPayload(values: SectionForm) !section_domain.Payload {
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

fn sectionCount(request: *context.RequestContext, version_id: i64) !u32 {
    const actor = try currentActor(request);
    var loaded = try request.server.document_service.loadDraftWithAllocator(request.allocator(), actor, version_id);
    defer loaded.deinit();
    return std.math.cast(u32, loaded.document.sections.len) orelse error.SectionLimitExceeded;
}

fn findSection(sections: []const domain.DraftSection, id: i64) ?usize {
    for (sections, 0..) |section, index| if (section.id == id) return index;
    return null;
}

fn requireEditorCsrf(request: *context.RequestContext, token: ?[]const u8) !bool {
    const session = auth.cookieValue(request, auth.session_cookie_name) orelse {
        web_logging.logDiagnostic(request, "warn", "auth.session_rejected", "editor request had no session cookie", .unauthorized, null, "missing session cookie");
        return false;
    };
    return auth.requireCsrf(request, session, token);
}

fn csrfToken(request: *context.RequestContext) ![]const u8 {
    return auth.cookieValue(request, auth.csrf_cookie_name) orelse {
        web_logging.logDiagnostic(request, "warn", "auth.csrf_rejected", "editor request had no CSRF cookie", .forbidden, null, "missing CSRF cookie");
        try errors.respond(request, .forbidden);
        return error.ResponseAlreadySent;
    };
}

fn parseId(value: []const u8) !i64 {
    const id = std.fmt.parseInt(i64, value, 10) catch return error.InvalidId;
    if (id <= 0) return error.InvalidId;
    return id;
}

fn detailsOpen(request: *const context.RequestContext) bool {
    return std.mem.eql(u8, queryParam(request, "details") orelse "0", "1");
}

fn titleEditing(request: *const context.RequestContext) bool {
    return std.mem.eql(u8, queryParam(request, "title") orelse "1", "1");
}

fn previewId(request: *const context.RequestContext) ?i64 {
    const value = queryParam(request, "preview") orelse return null;
    return parseId(value) catch null;
}

fn queryParam(request: *const context.RequestContext, name: []const u8) ?[]const u8 {
    const target = request.requestTarget();
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const separator = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..separator], name)) return pair[separator + 1 ..];
    }
    return null;
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
    try std.testing.expectEqual(@as(?usize, 4), route.resolve(routes, .GET, "/admin/theme.css"));
    try std.testing.expectEqual(@as(?usize, 5), route.resolve(routes, .GET, "/admin/editor-base.css"));
    try std.testing.expectEqual(@as(?usize, 6), route.resolve(routes, .GET, "/admin/editor-document.css"));
    try std.testing.expectEqual(@as(?usize, 7), route.resolve(routes, .GET, "/admin/editor-sections.css"));
    try std.testing.expectEqual(@as(?usize, 8), route.resolve(routes, .GET, "/admin/editor-documents.css"));
    try std.testing.expectEqual(@as(?usize, 9), route.resolve(routes, .GET, "/admin/editor-responsive.css"));
    try std.testing.expectEqual(@as(?usize, null), route.resolve(routes, .POST, "/admin/editor"));
}

test "editor template renders a text section" {
    const sections = [_]views.SectionItem{.{
        .id = 1,
        .kind = "text",
        .is_text = true,
        .is_preview = false,
        .is_first = true,
        .is_last = true,
        .markdown = "",
        .asset = "",
        .alt = "",
        .caption = "",
        .display_inline = true,
        .display_wide = false,
        .display_full = false,
        .preview_html = "",
    }};
    const page = views.Page{
        .page_title = "Draft",
        .kind = .editor,
        .csrf_token = "csrf",
        .has_notice = false,
        .notice_is_error = false,
        .notice = "",
        .documents = &.{},
        .has_documents = false,
        .document_id = 1,
        .version_id = 2,
        .revision = 1,
        .title = "Draft",
        .slug = "draft",
        .description = "",
        .has_description = false,
        .details_open = false,
        .title_editing = false,
        .title_value = "0",
        .details_toggle = "1",
        .details_value = "0",
        .details_label = "Document details",
        .sections = &sections,
        .has_sections = true,
        .has_multiple = false,
        .section_count = 1,
    };
    const rendered = try templates.pages.editor.renderAlloc(std.testing.allocator, page);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "name=\"markdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Signed in") != null);
}
