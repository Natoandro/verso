const std = @import("std");
const document = @import("../domain/document.zig");
const markdown = @import("../render/markdown.zig");
const application = @import("../application/documents.zig");

pub const DocumentItem = struct {
    document_id: i64,
    title: []const u8,
    slug: []const u8,
    revision: i64,
};

pub const PageKind = enum { document_list, editor };

pub const SectionItem = struct {
    id: i64,
    kind: []const u8,
    is_text: bool,
    is_preview: bool,
    is_first: bool,
    is_last: bool,
    markdown: []const u8,
    asset: []const u8,
    alt: []const u8,
    caption: []const u8,
    display_inline: bool,
    display_wide: bool,
    display_full: bool,
    preview_html: []const u8,
};

pub const Page = struct {
    page_title: []const u8,
    kind: PageKind,
    csrf_token: []const u8,
    has_notice: bool,
    notice_is_error: bool,
    notice: []const u8,
    documents: []const DocumentItem,
    has_documents: bool,
    document_id: i64,
    version_id: i64,
    revision: u64,
    title: []const u8,
    slug: []const u8,
    description: []const u8,
    has_description: bool,
    details_open: bool,
    title_editing: bool,
    title_value: []const u8,
    details_toggle: []const u8,
    details_value: []const u8,
    details_label: []const u8,
    sections: []const SectionItem,
    has_sections: bool,
    has_multiple: bool,
    section_count: usize,
};

pub fn list(
    allocator: std.mem.Allocator,
    csrf_token: []const u8,
    summaries: []const application.DraftSummary,
    notice: []const u8,
    notice_is_error: bool,
) !Page {
    const items = try allocator.alloc(DocumentItem, summaries.len);
    for (summaries, 0..) |summary, index| {
        items[index] = .{
            .document_id = summary.document_id,
            .title = summary.title,
            .slug = summary.slug,
            .revision = summary.revision_number,
        };
    }
    return .{
        .page_title = "Documents",
        .kind = .document_list,
        .csrf_token = csrf_token,
        .has_notice = notice.len > 0,
        .notice_is_error = notice_is_error,
        .notice = notice,
        .documents = items,
        .has_documents = items.len > 0,
        .document_id = 0,
        .version_id = 0,
        .revision = 0,
        .title = "",
        .slug = "",
        .description = "",
        .has_description = false,
        .details_open = false,
        .title_editing = false,
        .title_value = "0",
        .details_toggle = "1",
        .details_value = "0",
        .details_label = "Document details",
        .sections = &.{},
        .has_sections = false,
        .has_multiple = false,
        .section_count = 0,
    };
}

pub fn editor(
    allocator: std.mem.Allocator,
    csrf_token: []const u8,
    draft: document.DraftDocument,
    details_open: bool,
    title_editing: bool,
    preview_id: ?i64,
    notice: []const u8,
    notice_is_error: bool,
) !Page {
    const items = try allocator.alloc(SectionItem, draft.sections.len);
    for (draft.sections, 0..) |draft_section, index| {
        items[index] = try makeSectionItem(allocator, draft_section, index, draft.sections.len, preview_id);
    }
    return .{
        .page_title = draft.title,
        .kind = .editor,
        .csrf_token = csrf_token,
        .has_notice = notice.len > 0,
        .notice_is_error = notice_is_error,
        .notice = notice,
        .documents = &.{},
        .has_documents = false,
        .document_id = draft.document_id,
        .version_id = draft.version_id,
        .revision = draft.revision_number,
        .title = draft.title,
        .slug = draft.slug,
        .description = draft.description orelse "",
        .has_description = draft.description != null and draft.description.?.len > 0,
        .details_open = details_open,
        .title_editing = title_editing,
        .title_value = if (title_editing) "1" else "0",
        .details_toggle = if (details_open) "0" else "1",
        .details_value = if (details_open) "1" else "0",
        .details_label = if (details_open) "Hide details" else "Document details",
        .sections = items,
        .has_sections = items.len > 0,
        .has_multiple = items.len != 1,
        .section_count = items.len,
    };
}

pub fn sectionItem(
    allocator: std.mem.Allocator,
    draft: document.DraftDocument,
    section_id: i64,
    preview_id: ?i64,
) !SectionItem {
    for (draft.sections, 0..) |section_value, index| {
        const id = section_value.id orelse return error.InvalidStoredSection;
        if (id == section_id) return makeSectionItem(allocator, section_value, index, draft.sections.len, preview_id);
    }
    return error.SectionNotFound;
}

fn makeSectionItem(
    allocator: std.mem.Allocator,
    draft_section: document.DraftSection,
    index: usize,
    section_count: usize,
    preview_id: ?i64,
) !SectionItem {
    const id = draft_section.id orelse return error.InvalidStoredSection;
    var item = SectionItem{
        .id = id,
        .kind = draft_section.payload.kind().name(),
        .is_text = switch (draft_section.payload) {
            .text => true,
            .image => false,
        },
        .is_preview = preview_id != null and preview_id.? == id,
        .is_first = index == 0,
        .is_last = index + 1 == section_count,
        .markdown = "",
        .asset = "",
        .alt = "",
        .caption = "",
        .display_inline = true,
        .display_wide = false,
        .display_full = false,
        .preview_html = "",
    };
    switch (draft_section.payload) {
        .text => |text| {
            item.markdown = text.markdown;
            if (item.is_preview) item.preview_html = try markdown.renderAlloc(allocator, text.markdown);
        },
        .image => |image| {
            item.asset = image.asset;
            item.alt = image.alt;
            item.caption = image.caption orelse "";
            const display = image.display orelse .inline_display;
            item.display_inline = display == .inline_display;
            item.display_wide = display == .wide;
            item.display_full = display == .full;
            if (item.is_preview) item.preview_html = try markdown.imagePlaceholder(allocator, image.alt, image.caption);
        },
    }
    return item;
}

test "editor view preserves draft sections and presentation flags" {
    const sections = [_]document.DraftSection{
        .{ .id = 8, .payload = .{ .text = .{ .markdown = "# Title" } } },
    };
    const draft = document.DraftDocument{
        .document_id = 1,
        .version_id = 2,
        .version_number = 1,
        .revision_number = 3,
        .document_type = .article,
        .title = "Draft",
        .slug = "draft",
        .description = null,
        .language = "en",
        .sections = &sections,
    };
    const page = try editor(std.testing.allocator, "csrf", draft, false, false, 8, "", false);
    defer std.testing.allocator.free(page.sections);
    defer std.testing.allocator.free(page.sections[0].preview_html);
    try std.testing.expect(page.sections[0].is_preview);
    try std.testing.expectEqualStrings("<h1>Title</h1>", page.sections[0].preview_html);
}
