const std = @import("std");
const auth_identity = @import("../auth/identity.zig");
const storage = @import("../storage/document_access.zig");
const identity = @import("identity.zig");

pub fn userHasCapability(
    service: *identity.Service,
    user_id: i64,
    capability: auth_identity.Capability,
) !bool {
    inline for (std.meta.tags(auth_identity.Role)) |role| {
        if (try service.store.userHasRole(user_id, role) and auth_identity.roleGrants(role, capability)) return true;
    }
    return false;
}

pub fn requireUserCapability(
    service: *identity.Service,
    user_id: i64,
    capability: auth_identity.Capability,
) !void {
    if (!(try userHasCapability(service, user_id, capability))) return error.Forbidden;
}

pub fn requireUserAuthorRead(service: *identity.Service, user_id: i64, author_id: i64) !void {
    if (try userHasCapability(service, user_id, .document_read_any)) return;
    try requireUserCapability(service, user_id, .document_read_assigned);
    if (!try service.store.hasAuthorAssignment(user_id, author_id)) return error.Forbidden;
}

pub fn requireUserDocumentRead(service: *identity.Service, user_id: i64, document_id: i64) !void {
    if (try userHasCapability(service, user_id, .document_read_any)) return;
    try requireUserCapability(service, user_id, .document_read_assigned);
    if (!try storage.hasDocumentReadAccess(service.store.database, user_id, document_id)) return error.Forbidden;
}

pub fn requireUserVersionRead(service: *identity.Service, user_id: i64, version_id: i64) !void {
    if (try userHasCapability(service, user_id, .document_read_any)) return;
    try requireUserCapability(service, user_id, .document_read_assigned);
    if (!try storage.hasVersionReadAccess(service.store.database, user_id, version_id)) return error.Forbidden;
}

pub fn requireUserDocumentUpdate(service: *identity.Service, user_id: i64, document_id: i64) !void {
    if (try userHasCapability(service, user_id, .document_update_any)) return;
    try requireUserCapability(service, user_id, .document_update_assigned);
    if (!try storage.hasDocumentUpdateAccess(service.store.database, user_id, document_id)) return error.Forbidden;
}

pub fn requireUserVersionUpdate(service: *identity.Service, user_id: i64, version_id: i64) !void {
    if (try userHasCapability(service, user_id, .document_update_any)) return;
    try requireUserCapability(service, user_id, .document_update_assigned);
    if (!try storage.hasVersionUpdateAccess(service.store.database, user_id, version_id)) return error.Forbidden;
}
