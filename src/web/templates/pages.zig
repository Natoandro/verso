const tmpl = @import("tmpl");
const components = @import("components.zig");

pub const auth_login = tmpl.parse(@embedFile("pages/login.html"), .{});
pub const auth_register = tmpl.parse(@embedFile("pages/register.html"), .{});
pub const auth_password = tmpl.parse(@embedFile("pages/password.html"), .{});
pub const auth_recovery = tmpl.parse(@embedFile("pages/recovery.html"), .{});
pub const auth_recovery_complete = tmpl.parse(@embedFile("pages/recovery_complete.html"), .{});

pub const error_page = tmpl.parse(@embedFile("pages/error.html"), .{});

pub const editor = tmpl.parse(@embedFile("pages/editor.html"), .{
    .components = .{
        .head = components.editor_head,
        .section_card = components.editor_section,
        .icon_check = components.icon_check,
        .icon_details = components.icon_details,
        .icon_edit = components.icon_edit,
        .icon_image = components.icon_image,
        .icon_text = components.icon_text,
    },
});

pub const document_list = tmpl.parse(@embedFile("pages/document_list.html"), .{
    .components = .{ .head = components.editor_head },
});

pub const management = tmpl.parse(@embedFile("pages/management.html"), .{});
