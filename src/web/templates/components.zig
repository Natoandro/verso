const tmpl = @import("tmpl");

pub const admin_header = tmpl.parse(@embedFile("components/admin_header.html"), .{
    .parameters = .{ .csrf_token = {}, .is_authenticated = {} },
});

pub const editor_head = tmpl.parse(@embedFile("components/editor_head.html"), .{
    .parameters = .{ .page_title = {} },
});

pub const icon_check = tmpl.parse(@embedFile("components/icon_check.html"), .{});
pub const icon_copy = tmpl.parse(@embedFile("components/icon_copy.html"), .{});
pub const icon_delete = tmpl.parse(@embedFile("components/icon_delete.html"), .{});
pub const icon_details = tmpl.parse(@embedFile("components/icon_details.html"), .{});
pub const icon_down = tmpl.parse(@embedFile("components/icon_down.html"), .{});
pub const icon_edit = tmpl.parse(@embedFile("components/icon_edit.html"), .{});
pub const icon_image = tmpl.parse(@embedFile("components/icon_image.html"), .{});
pub const icon_text = tmpl.parse(@embedFile("components/icon_text.html"), .{});
pub const icon_up = tmpl.parse(@embedFile("components/icon_up.html"), .{});

pub const editor_section = tmpl.parse(@embedFile("components/editor_section.html"), .{
    .parameters = .{
        .section = {},
        .csrf_token = {},
        .document_id = {},
        .version_id = {},
        .revision = {},
        .details_value = {},
        .title_value = {},
    },
    .components = .{
        .icon_check = icon_check,
        .icon_copy = icon_copy,
        .icon_delete = icon_delete,
        .icon_down = icon_down,
        .icon_edit = icon_edit,
        .icon_up = icon_up,
    },
});
