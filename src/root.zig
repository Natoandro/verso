pub const config = @import("config.zig");
pub const logging = @import("logging.zig");
pub const tmpl = @import("tmpl");
pub const application = struct {
    pub const bootstrap = @import("application/bootstrap.zig");
    pub const documents = @import("application/documents.zig");
};
pub const domain = struct {
    pub const document = @import("domain/document.zig");
    pub const sections = @import("domain/sections.zig");
};
pub const storage = struct {
    pub const documents = @import("storage/documents.zig");
    pub const sections = @import("storage/sections.zig");
    pub const migration_directory = @import("storage/migration_directory.zig");
    pub const migrations = @import("storage/migrations.zig");
    pub const sqlite = @import("storage/sqlite.zig");
};

test {
    _ = @import("domain/document.zig");
    _ = @import("domain/sections.zig");
    _ = @import("application/documents.zig");
    _ = @import("storage/documents.zig");
    _ = @import("storage/sections.zig");
    _ = @import("logging_test.zig");
    _ = @import("template/tests.zig");
    _ = @import("storage/sqlite.zig");
}
pub const server = @import("server.zig");
pub const web = @import("web.zig");

test {
    _ = @import("web.zig");
}
