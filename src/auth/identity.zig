const std = @import("std");

pub const UserState = enum {
    active,
    disabled,
};

pub const Role = enum {
    owner,
    manager,
    editor,
    author,
    contributor,
};

pub const Capability = enum {
    document_create,
    document_read_assigned,
    document_read_any,
    document_update_assigned,
    document_update_any,
    document_assign_editor,
    document_review,
    document_publish,
    document_finalize,
    document_archive_manage,
    author_manage,
    asset_read,
    asset_upload,
    interactive_create,
    interactive_publish,
    user_manage,

    pub fn text(self: Capability) []const u8 {
        return switch (self) {
            .document_create => "document:create",
            .document_read_assigned => "document:read:assigned",
            .document_read_any => "document:read:any",
            .document_update_assigned => "document:update:assigned",
            .document_update_any => "document:update:any",
            .document_assign_editor => "document:assign_editor",
            .document_review => "document:review",
            .document_publish => "document:publish",
            .document_finalize => "document:finalize",
            .document_archive_manage => "document:archive:manage",
            .author_manage => "author:manage",
            .asset_read => "asset:read",
            .asset_upload => "asset:upload",
            .interactive_create => "interactive:create",
            .interactive_publish => "interactive:publish",
            .user_manage => "user:manage",
        };
    }
};

pub const User = struct {
    id: i64,
    subject: []const u8,
    display_name: []const u8,
    email: ?[]const u8,
    state: UserState,
};

pub const BootstrapOwner = struct {
    subject: []const u8,
    display_name: []const u8,
    email: ?[]const u8 = null,
};

pub fn roleGrants(role: Role, capability: Capability) bool {
    return switch (role) {
        .owner => true,
        .manager => switch (capability) {
            .document_create,
            .document_read_any,
            .document_update_any,
            .document_assign_editor,
            .document_review,
            .document_publish,
            .document_finalize,
            .document_archive_manage,
            .author_manage,
            .asset_read,
            .asset_upload,
            .interactive_create,
            .interactive_publish,
            .user_manage,
            => true,
            else => false,
        },
        .editor => switch (capability) {
            .document_create,
            .document_read_assigned,
            .document_update_assigned,
            .asset_read,
            .asset_upload,
            => true,
            else => false,
        },
        .author, .contributor => false,
    };
}

pub fn validateBootstrapOwner(owner: BootstrapOwner) !void {
    try validateOpaqueText(owner.subject, 512, error.InvalidSubject);
    try validateDisplayName(owner.display_name);
    if (owner.email) |email| try validateEmail(email);
}

pub fn validateDisplayName(display_name: []const u8) !void {
    try validateOpaqueText(display_name, 256, error.InvalidDisplayName);
}

pub fn validateEmail(email: []const u8) !void {
    try validateOpaqueText(email, 320, error.InvalidEmail);
}

fn validateOpaqueText(value: []const u8, max_len: usize, invalid_error: anyerror) !void {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed.len > max_len) return invalid_error;
    for (trimmed) |character| {
        if (character < 0x20 or character == 0x7f) return invalid_error;
    }
}

test "owner bootstrap input rejects empty and control text" {
    try std.testing.expectError(error.InvalidSubject, validateBootstrapOwner(.{
        .subject = "",
        .display_name = "Owner",
    }));
    try std.testing.expectError(error.InvalidDisplayName, validateBootstrapOwner(.{
        .subject = "owner",
        .display_name = "bad\nname",
    }));
}

test "role capability boundaries are explicit" {
    try std.testing.expect(roleGrants(.owner, .user_manage));
    try std.testing.expect(roleGrants(.manager, .author_manage));
    try std.testing.expect(!roleGrants(.editor, .document_publish));
    try std.testing.expect(!roleGrants(.author, .document_update_assigned));
}
