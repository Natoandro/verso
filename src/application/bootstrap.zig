const std = @import("std");
const config_types = @import("../config.zig");

pub fn prepareConfiguredDirectories(
    io: std.Io,
    root: std.Io.Dir,
    app_config: config_types.Config,
) !void {
    try prepareDatabaseParentDirectory(io, root, app_config);

    switch (app_config.storage) {
        .filesystem => |filesystem| try root.createDirPath(io, filesystem.path),
    }
    try root.createDirPath(io, app_config.cache.path);
}

pub fn prepareDatabaseParentDirectory(
    io: std.Io,
    root: std.Io.Dir,
    app_config: config_types.Config,
) !void {
    var database_path_buffer: [1024]u8 = undefined;
    const database_path = try resolveDatabasePath(app_config, &database_path_buffer);
    try createParentDirectory(io, root, database_path);
}

pub fn resolveDatabasePath(app_config: config_types.Config, buffer: []u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, app_config.database.url, ':') == null) {
        return app_config.database.url;
    }

    const database_uri = try std.Uri.parse(app_config.database.url);
    if (!database_uri.path.isEmpty()) {
        const database_path = try database_uri.path.toRaw(buffer);
        if (std.mem.startsWith(u8, database_path, "/./")) return database_path[1..];
        return database_path;
    }
    if (database_uri.host) |database_host| return database_host.toRaw(buffer);
    return error.InvalidDatabaseUrl;
}

fn createParentDirectory(io: std.Io, root: std.Io.Dir, path: []const u8) !void {
    const parent_path = std.fs.path.dirname(path) orelse return;
    if (parent_path.len == 0) return;
    try root.createDirPath(io, parent_path);
}

test "prepareConfiguredDirectories creates database, asset, and cache parents" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var app_config = config_types.Config{};
    app_config.database.url = "nested/db/verso.db";
    app_config.storage = .{ .filesystem = .{ .path = "nested/assets" } };
    app_config.cache.path = "nested/cache";

    try prepareConfiguredDirectories(std.testing.io, temporary_directory.dir, app_config);

    var database_parent = try temporary_directory.dir.openDir(std.testing.io, "nested/db", .{});
    database_parent.close(std.testing.io);
    var asset_directory = try temporary_directory.dir.openDir(std.testing.io, "nested/assets", .{});
    asset_directory.close(std.testing.io);
    var cache_directory = try temporary_directory.dir.openDir(std.testing.io, "nested/cache", .{});
    cache_directory.close(std.testing.io);
}

test "prepareConfiguredDirectories is repeatable" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    const app_config = config_types.Config{};
    try prepareConfiguredDirectories(std.testing.io, temporary_directory.dir, app_config);
    try prepareConfiguredDirectories(std.testing.io, temporary_directory.dir, app_config);
}

test "prepareConfiguredDirectories rejects a file in a configured parent path" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var blocking_file = try temporary_directory.dir.createFile(std.testing.io, "blocked", .{});
    blocking_file.close(std.testing.io);

    var app_config = config_types.Config{};
    app_config.database.url = "blocked/verso.db";
    try std.testing.expectError(
        error.NotDir,
        prepareConfiguredDirectories(std.testing.io, temporary_directory.dir, app_config),
    );
}

test "resolveDatabasePath keeps relative SQLite URLs relative" {
    var app_config = config_types.Config{};
    app_config.database.url = "sqlite:///./data/verso.db";

    var database_path_buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(
        "./data/verso.db",
        try resolveDatabasePath(app_config, &database_path_buffer),
    );
}

test "resolveDatabasePath keeps absolute SQLite URLs absolute" {
    var app_config = config_types.Config{};
    app_config.database.url = "sqlite:///var/lib/verso.db";

    var database_path_buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/var/lib/verso.db",
        try resolveDatabasePath(app_config, &database_path_buffer),
    );
}
