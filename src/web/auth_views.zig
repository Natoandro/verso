const std = @import("std");
const tmpl = @import("tmpl");

const admin_header = tmpl.parse(@embedFile("templates/components/admin_header.html"), .{
    .parameters = .{ .csrf_token = {}, .is_authenticated = {} },
});
const login_template = tmpl.parse(@embedFile("templates/pages/login.html"), .{
    .components = .{ .admin_header = admin_header },
});
const register_template = tmpl.parse(@embedFile("templates/pages/register.html"), .{
    .components = .{ .admin_header = admin_header },
});
const password_template = tmpl.parse(@embedFile("templates/pages/password.html"), .{
    .components = .{ .admin_header = admin_header },
});
const recovery_template = tmpl.parse(@embedFile("templates/pages/recovery.html"), .{
    .components = .{ .admin_header = admin_header },
});
const recovery_complete_template = tmpl.parse(@embedFile("templates/pages/recovery_complete.html"), .{
    .components = .{ .admin_header = admin_header },
});

pub fn login(allocator: std.mem.Allocator, message: ?[]const u8) ![]u8 {
    return login_template.renderAlloc(allocator, .{
        .has_error = message != null,
        .error_message = message orelse "",
        .csrf_token = "",
        .is_authenticated = false,
    });
}

pub fn register(allocator: std.mem.Allocator, csrf_token: []const u8) ![]u8 {
    return register_template.renderAlloc(allocator, .{
        .csrf_token = csrf_token,
        .is_authenticated = false,
    });
}

pub fn password(allocator: std.mem.Allocator, csrf_token: []const u8) ![]u8 {
    return password_template.renderAlloc(allocator, .{
        .csrf_token = csrf_token,
        .is_authenticated = true,
    });
}

pub fn recovery(allocator: std.mem.Allocator) ![]u8 {
    return recovery_template.renderAlloc(allocator, .{
        .csrf_token = "",
        .is_authenticated = false,
    });
}

pub fn recoveryComplete(allocator: std.mem.Allocator) ![]u8 {
    return recovery_complete_template.renderAlloc(allocator, .{
        .csrf_token = "",
        .is_authenticated = false,
    });
}

pub fn loginFeedback(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("<p class=\"auth-feedback-error\" role=\"alert\">");
    try tmpl.escape.write(&output.writer, message, true);
    try output.writer.writeAll("</p>");
    return output.toOwnedSlice();
}
