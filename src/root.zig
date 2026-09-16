pub const config = @import("config.zig");
pub const logging = @import("logging.zig");
pub const application = struct {
    pub const bootstrap = @import("application/bootstrap.zig");
};
pub const storage = struct {
    pub const migration_directory = @import("storage/migration_directory.zig");
    pub const migrations = @import("storage/migrations.zig");
    pub const sqlite = @import("storage/sqlite.zig");
};

test {
    _ = @import("logging_test.zig");
    _ = @import("storage/sqlite.zig");
}
pub const server = @import("server.zig");
pub const web = @import("web.zig");
