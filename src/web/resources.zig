const StaticResource = @import("resource.zig").StaticResource;

pub const theme_css = StaticResource.init(
    "GET /admin/theme.css",
    @embedFile("styles/theme.css"),
    .{ .version = .content_hash },
);

pub const auth_css = StaticResource.init(
    "GET /admin/auth.css",
    @embedFile("styles/auth.css"),
    .{ .version = .content_hash },
);

pub const admin_css = StaticResource.init(
    "GET /admin/admin.css",
    @embedFile("styles/admin.css"),
    .{ .version = .content_hash },
);

pub const editor_base_css = StaticResource.init(
    "GET /admin/editor-base.css",
    @embedFile("styles/editor/base.css"),
    .{ .version = .content_hash },
);

pub const editor_document_css = StaticResource.init(
    "GET /admin/editor-document.css",
    @embedFile("styles/editor/document.css"),
    .{ .version = .content_hash },
);

pub const editor_sections_css = StaticResource.init(
    "GET /admin/editor-sections.css",
    @embedFile("styles/editor/sections.css"),
    .{ .version = .content_hash },
);

pub const editor_documents_css = StaticResource.init(
    "GET /admin/editor-documents.css",
    @embedFile("styles/editor/documents.css"),
    .{ .version = .content_hash },
);

pub const editor_responsive_css = StaticResource.init(
    "GET /admin/editor-responsive.css",
    @embedFile("styles/editor/responsive.css"),
    .{ .version = .content_hash },
);

pub const Css = struct {
    theme: []const u8,
    auth: []const u8,
    admin: []const u8,
    editor_base: []const u8,
    editor_document: []const u8,
    editor_sections: []const u8,
    editor_documents: []const u8,
    editor_responsive: []const u8,
};

pub const css: Css = .{
    .theme = theme_css.href(),
    .auth = auth_css.href(),
    .admin = admin_css.href(),
    .editor_base = editor_base_css.href(),
    .editor_document = editor_document_css.href(),
    .editor_sections = editor_sections_css.href(),
    .editor_documents = editor_documents_css.href(),
    .editor_responsive = editor_responsive_css.href(),
};
