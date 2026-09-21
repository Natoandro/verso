pub const config = @import("config.zig");
pub const logging = @import("logging.zig");
pub const tmpl = @import("tmpl");
pub const auth = @import("auth.zig");
pub const application = struct {
    pub const bootstrap = @import("application/bootstrap.zig");
    pub const documents = @import("application/documents.zig");
    pub const document_access = @import("application/document_access.zig");
    pub const identity = @import("application/identity.zig");
    pub const initial_owner = @import("application/initial_owner.zig");
    pub const identity_management = @import("application/identity_management.zig");
};
pub const domain = struct {
    pub const document = @import("domain/document.zig");
    pub const identity = @import("domain/identity.zig");
    pub const sections = @import("domain/sections.zig");
};
pub const storage = struct {
    pub const assets = @import("storage/assets.zig");
    pub const documents = @import("storage/documents.zig");
    pub const document_versions = @import("storage/document_versions.zig");
    pub const document_access = @import("storage/document_access.zig");
    pub const identity = @import("storage/identity.zig");
    pub const identity_queries = @import("storage/identity_queries.zig");
    pub const local_auth = @import("storage/local_auth.zig");
    pub const sections = @import("storage/sections.zig");
    pub const migration_directory = @import("storage/migration_directory.zig");
    pub const migrations = @import("storage/migrations.zig");
    pub const sqlite = @import("storage/sqlite.zig");
};

test {
    _ = @import("auth/crypto.zig");
    _ = @import("auth/identity.zig");
    _ = @import("auth/password.zig");
    _ = @import("auth/security.zig");
    _ = @import("domain/document.zig");
    _ = @import("domain/identity.zig");
    _ = @import("domain/sections.zig");
    _ = @import("application/documents.zig");
    _ = @import("application/document_access.zig");
    _ = @import("application/identity.zig");
    _ = @import("application/identity_local_test.zig");
    _ = @import("application/initial_owner.zig");
    _ = @import("application/identity_management.zig");
    _ = @import("application/documents_test.zig");
    _ = @import("application/documents_authorization_test.zig");
    _ = @import("storage/documents.zig");
    _ = @import("storage/assets.zig");
    _ = @import("storage/document_versions.zig");
    _ = @import("storage/document_access.zig");
    _ = @import("storage/identity.zig");
    _ = @import("storage/identity_queries.zig");
    _ = @import("storage/local_auth.zig");
    _ = @import("storage/sections.zig");
    _ = @import("logging_test.zig");
    _ = @import("template/tests.zig");
    _ = @import("storage/sqlite.zig");
}
pub const server = @import("server.zig");
pub const web = @import("web.zig");

test {
    _ = @import("web.zig");
    _ = @import("web/form.zig");
    _ = @import("web/static.zig");
    _ = @import("web/auth_test.zig");
    _ = @import("web/router_test.zig");
}
