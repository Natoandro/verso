const std = @import("std");
const domain = @import("../domain/document.zig");
const section_domain = @import("../domain/sections.zig");
const auth = @import("auth.zig");
const context = @import("context.zig");
const helpers = @import("editor_helpers.zig");
const form = @import("form.zig");
const layer = @import("layer.zig");
const route = @import("router.zig");
const resources = @import("resources.zig");
const templates = @import("templates/root.zig");
const views = @import("editor_view.zig");
const web_logging = @import("logging.zig");

const section_editor_response_headers = [_]std.http.Header{
    .{ .name = "HX-Retarget", .value = "#editor" },
    .{ .name = "HX-Reselect", .value = "#editor" },
};
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
    editor_details: ?[]const u8,
    editor_title: ?[]const u8,
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
    resources.theme_css.route(),
    resources.editor_base_css.route(),
    resources.editor_document_css.route(),
    resources.editor_sections_css.route(),
    resources.editor_documents_css.route(),
    resources.editor_responsive_css.route(),
});

fn getEditor(request: *context.RequestContext, _: layer.Next) anyerror!void {
    const actor = try helpers.currentActor(request);
    const csrf = try helpers.csrfToken(request);
    const document_text = helpers.queryParam(request, "document") orelse return renderList(request, csrf, "", false);
    const document_id = helpers.parseId(document_text) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.request_rejected", "document identifier was rejected", .ok, failure, "invalid document id");
        return renderList(request, csrf, "Invalid document.", true);
    };
    const version_id = request.server.document_service.mutableVersionForDocument(actor, document_id) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.load_rejected", "editable document could not be selected", .ok, failure, "document lookup failed");
        return renderList(request, csrf, helpers.failureMessage(failure), true);
    };
    return renderDocument(request, csrf, version_id, helpers.detailsOpen(request), helpers.titleEditing(request), helpers.editId(request), "", false);
}

fn createDraft(request: *context.RequestContext, _: layer.Next) anyerror!void {
    const actor = try helpers.currentActor(request);
    var parsed = form.extract(CreateDraftForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.request_rejected", "draft form was rejected", .bad_request, failure, "invalid draft form");
        return auth.respondText(request, "Invalid draft form\n", .bad_request);
    };
    defer parsed.deinit(request.allocator());
    if (!try helpers.requireEditorCsrf(request, parsed.value.csrf_token)) return;
    const csrf = try helpers.csrfToken(request);
    const draft = request.server.document_service.createDraftWithAllocator(request.allocator(), actor, .{
        .document_type = .article,
        .title = parsed.value.title,
        .slug = parsed.value.slug,
        .description = null,
        .language = "en",
        .markdown = "",
    }) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.draft_failed", "draft creation failed", .ok, failure, null);
        return renderList(request, csrf, helpers.failureMessage(failure), true);
    };
    return renderDocument(request, csrf, draft.version_id, false, false, null, "Draft created.", false);
}

fn saveDocument(request: *context.RequestContext, _: layer.Next) anyerror!void {
    const actor = try helpers.currentActor(request);
    var parsed = form.extract(SaveDocumentForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.request_rejected", "document form was rejected", .bad_request, failure, "invalid document form");
        return auth.respondText(request, "Invalid document form\n", .bad_request);
    };
    defer parsed.deinit(request.allocator());
    if (!try helpers.requireEditorCsrf(request, parsed.value.csrf_token)) return;
    const csrf = try helpers.csrfToken(request);
    const document_id = parsed.value.document_id;
    const version_id = parsed.value.version_id;
    const expected_revision = parsed.value.expected_revision;
    var loaded = request.server.document_service.loadDraftWithAllocator(request.allocator(), actor, version_id) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.load_failed", "draft could not be loaded for saving", .ok, failure, null);
        return renderDocumentById(request, csrf, document_id, helpers.failureMessage(failure), true);
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
        .subject_ids = loaded.document.subject_ids,
        .series_id = loaded.document.series_id,
        .series_position = loaded.document.series_position,
        .sections = draft_sections,
    }) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.document_save_failed", "draft save failed", .ok, failure, null);
        return renderDocument(request, csrf, version_id, helpers.detailsOpen(request), helpers.titleEditing(request), null, helpers.failureMessage(failure), true);
    };
    return renderDocument(request, csrf, version_id, helpers.detailsOpen(request), false, null, "Draft saved.", false);
}

fn mutateSection(request: *context.RequestContext, _: layer.Next) anyerror!void {
    const actor = try helpers.currentActor(request);
    var parsed = form.extract(SectionForm, request) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.request_rejected", "section form was rejected", .bad_request, failure, "invalid section form");
        return auth.respondText(request, "Invalid section form\n", .bad_request);
    };
    defer parsed.deinit(request.allocator());
    if (!try helpers.requireEditorCsrf(request, parsed.value.csrf_token)) return;
    const csrf = try helpers.csrfToken(request);
    const document_id = parsed.value.document_id;
    const version_id = parsed.value.version_id;
    const expected_revision = parsed.value.expected_revision;
    const operation = parsed.value.operation;

    if (std.mem.eql(u8, operation, "insert-text") or std.mem.eql(u8, operation, "insert-image")) {
        const payload: section_domain.Payload = if (std.mem.eql(u8, operation, "insert-text"))
            .{ .text = .{ .markdown = "" } }
        else
            .{ .image = .{ .asset = "placeholder.png", .alt = "Image placeholder", .caption = null, .display = .inline_display } };
        const position = helpers.sectionCount(request, version_id) catch |failure| {
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
            return renderDocument(request, csrf, version_id, false, false, null, helpers.failureMessage(failure), true);
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
        return renderDocumentWithHeaders(request, csrf, version_id, helpers.detailsOpen(request), helpers.titleEditing(request), section_id, helpers.failureMessage(failure), true, &section_editor_response_headers);
    };
    defer loaded.deinit();
    const index = helpers.findSection(loaded.document.sections, section_id) orelse {
        web_logging.logDiagnostic(request, "warn", "editor.request_rejected", "section was not found", .ok, error.SectionNotFound, "section not found");
        return renderDocumentWithHeaders(request, csrf, version_id, false, false, section_id, "Section not found.", true, &section_editor_response_headers);
    };

    if (std.mem.eql(u8, operation, "move-up") or std.mem.eql(u8, operation, "move-down")) {
        const target: u32 = if (std.mem.eql(u8, operation, "move-up"))
            @intCast(index -| 1)
        else
            @intCast(@min(index + 1, loaded.document.sections.len - 1));
        _ = request.server.document_service.moveSection(actor, .{ .version_id = version_id, .section_id = section_id, .position = target, .expected_revision = expected_revision }) catch |failure| {
            web_logging.logDiagnostic(request, "warn", "editor.section_mutation_failed", "section move failed", .ok, failure, null);
            return renderDocumentWithHeaders(request, csrf, version_id, false, false, null, helpers.failureMessage(failure), true, &section_editor_response_headers);
        };
        return renderDocument(request, csrf, version_id, false, false, null, "Section order updated.", false);
    }
    if (std.mem.eql(u8, operation, "duplicate")) {
        _ = request.server.document_service.duplicateSection(actor, .{ .version_id = version_id, .section_id = section_id, .position = @intCast(index + 1), .expected_revision = expected_revision }) catch |failure| {
            web_logging.logDiagnostic(request, "warn", "editor.section_mutation_failed", "section duplication failed", .ok, failure, null);
            return renderDocumentWithHeaders(request, csrf, version_id, false, false, null, helpers.failureMessage(failure), true, &section_editor_response_headers);
        };
        return renderDocument(request, csrf, version_id, false, false, null, "Section duplicated.", false);
    }
    if (std.mem.eql(u8, operation, "delete")) {
        _ = request.server.document_service.deleteSection(actor, .{ .version_id = version_id, .section_id = section_id, .expected_revision = expected_revision }) catch |failure| {
            web_logging.logDiagnostic(request, "warn", "editor.section_mutation_failed", "section deletion failed", .ok, failure, null);
            return renderDocumentWithHeaders(request, csrf, version_id, false, false, null, helpers.failureMessage(failure), true, &section_editor_response_headers);
        };
        return renderDocument(request, csrf, version_id, false, false, null, "Section deleted.", false);
    }

    const payload = helpers.sectionPayload(parsed.value) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.request_rejected", "section payload was rejected", .ok, failure, "invalid section payload");
        return renderDocumentWithHeaders(request, csrf, version_id, helpers.detailsOpen(request), helpers.titleEditing(request), section_id, helpers.failureMessage(failure), true, &section_editor_response_headers);
    };
    _ = request.server.document_service.updateSectionWithAllocator(request.allocator(), actor, .{ .version_id = version_id, .section_id = section_id, .expected_revision = expected_revision, .payload = payload }) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.section_mutation_failed", "section update failed", .ok, failure, null);
        return renderDocumentWithHeaders(request, csrf, version_id, helpers.detailsOpen(request), helpers.titleEditing(request), section_id, helpers.failureMessage(failure), true, &section_editor_response_headers);
    };
    const show_preview = std.mem.eql(u8, operation, "preview");
    if (show_preview) return renderSection(request, csrf, version_id, section_id, parsed.value.editor_details, parsed.value.editor_title);
    return renderDocument(request, csrf, version_id, false, false, null, "Section saved.", false);
}

fn renderList(request: *context.RequestContext, csrf: []const u8, notice: []const u8, is_error: bool) !void {
    const actor = try helpers.currentActor(request);
    const summaries = request.server.document_service.listDrafts(actor, request.allocator()) catch |failure| return helpers.editorFailure(request, failure);
    defer for (summaries) |*summary| summary.deinit(request.allocator());
    const page = views.list(request.allocator(), csrf, summaries, notice, is_error) catch |failure| {
        web_logging.logDiagnostic(request, "error", "editor.render_failed", "editor list rendering failed", .internal_server_error, failure, null);
        return failure;
    };
    return helpers.respondPage(request, page);
}

fn renderDocumentById(request: *context.RequestContext, csrf: []const u8, document_id: i64, notice: []const u8, is_error: bool) !void {
    const actor = try helpers.currentActor(request);
    const version_id = request.server.document_service.mutableVersionForDocument(actor, document_id) catch |failure| {
        web_logging.logDiagnostic(request, "warn", "editor.load_failed", "document draft lookup failed", .ok, failure, null);
        return renderList(request, csrf, notice, is_error);
    };
    return renderDocument(request, csrf, version_id, false, false, null, notice, is_error);
}

fn renderDocument(request: *context.RequestContext, csrf: []const u8, version_id: i64, details_open: bool, title_editing: bool, edit_id: ?i64, notice: []const u8, is_error: bool) !void {
    return renderDocumentWithHeaders(request, csrf, version_id, details_open, title_editing, edit_id, notice, is_error, &.{});
}

fn renderDocumentWithHeaders(request: *context.RequestContext, csrf: []const u8, version_id: i64, details_open: bool, title_editing: bool, edit_id: ?i64, notice: []const u8, is_error: bool, extra_headers: []const std.http.Header) !void {
    const actor = try helpers.currentActor(request);
    var loaded = request.server.document_service.loadDraftWithAllocator(request.allocator(), actor, version_id) catch |failure| return helpers.editorFailure(request, failure);
    defer loaded.deinit();
    const page = views.editor(request.allocator(), csrf, loaded.document, details_open, title_editing, edit_id, notice, is_error) catch |failure| {
        web_logging.logDiagnostic(request, "error", "editor.render_failed", "editor document rendering failed", .internal_server_error, failure, null);
        return failure;
    };
    return helpers.respondPageWithHeaders(request, page, extra_headers);
}

fn renderSection(request: *context.RequestContext, csrf: []const u8, version_id: i64, section_id: i64, details_value: ?[]const u8, title_value: ?[]const u8) !void {
    const actor = try helpers.currentActor(request);
    var loaded = request.server.document_service.loadDraftWithAllocator(request.allocator(), actor, version_id) catch |failure| {
        web_logging.logDiagnostic(request, "error", "editor.section_load_failed", "updated section could not be loaded for rendering", .internal_server_error, failure, null);
        return helpers.editorFailure(request, failure);
    };
    defer loaded.deinit();
    const details_open = if (details_value) |value| std.mem.eql(u8, value, "1") else helpers.detailsOpen(request);
    const title_editing = if (title_value) |value| std.mem.eql(u8, value, "1") else helpers.titleEditing(request);
    const target = try std.fmt.allocPrint(request.allocator(), "#section-{}", .{section_id});
    const trigger = try std.fmt.allocPrint(request.allocator(), "{{\"editorRevision\":{{\"revision\":\"{}\"}}}}", .{loaded.document.revision_number});
    const headers = [_]std.http.Header{
        .{ .name = "HX-Retarget", .value = target },
        .{ .name = "HX-Reselect", .value = target },
        .{ .name = "HX-Trigger", .value = trigger },
    };
    return renderDocumentWithHeaders(request, csrf, version_id, details_open, title_editing, null, "Section saved and previewed.", false, &headers) catch |failure| {
        web_logging.logDiagnostic(request, "error", "editor.section_render_failed", "updated section view could not be built", .internal_server_error, failure, null);
        return renderDocumentWithHeaders(request, csrf, version_id, details_open, title_editing, section_id, "Section saved, but the preview could not be rendered.", true, &section_editor_response_headers);
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
        .css = resources.css,
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, "href=\"/admin/theme.css?v=") != null);
}
