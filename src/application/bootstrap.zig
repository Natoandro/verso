const std = @import("std");
const config_types = @import("../config.zig");

pub fn prepareConfiguredDirectories(
    io: std.Io,
    root: std.Io.Dir,
    allocator: std.mem.Allocator,
    app_config: config_types.Config,
) !void {
    try prepareDatabaseParentDirectory(io, root, allocator, app_config);

    switch (app_config.storage) {
        .filesystem => |filesystem| try root.createDirPath(io, filesystem.path),
    }
    try root.createDirPath(io, app_config.cache.path);
}

pub fn prepareDatabaseParentDirectory(
    io: std.Io,
    root: std.Io.Dir,
    allocator: std.mem.Allocator,
    app_config: config_types.Config,
) !void {
    const database_path = try resolveDatabasePath(allocator, app_config);
    defer allocator.free(database_path);
    try createParentDirectory(io, root, database_path);
}

pub fn resolveDatabasePath(allocator: std.mem.Allocator, app_config: config_types.Config) ![]u8 {
    if (std.mem.indexOfScalar(u8, app_config.database.url, ':') == null) {
        return allocator.dupe(u8, app_config.database.url);
    }

    const database_uri = std.Uri.parse(app_config.database.url) catch return error.InvalidDatabaseUrl;
    const component = if (!database_uri.path.isEmpty())
        database_uri.path
    else
        database_uri.host orelse return error.InvalidDatabaseUrl;
    const raw_path = try std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(component, .formatRaw)});
    defer allocator.free(raw_path);
    if (std.mem.startsWith(u8, raw_path, "/./")) return allocator.dupe(u8, raw_path[1..]);
    return allocator.dupe(u8, raw_path);
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

    try prepareConfiguredDirectories(std.testing.io, temporary_directory.dir, std.testing.allocator, app_config);

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
    try prepareConfiguredDirectories(std.testing.io, temporary_directory.dir, std.testing.allocator, app_config);
    try prepareConfiguredDirectories(std.testing.io, temporary_directory.dir, std.testing.allocator, app_config);
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
        prepareConfiguredDirectories(std.testing.io, temporary_directory.dir, std.testing.allocator, app_config),
    );
}

test "resolveDatabasePath keeps relative SQLite URLs relative" {
    var app_config = config_types.Config{};
    app_config.database.url = "sqlite:///./data/verso.db";

    const database_path = try resolveDatabasePath(std.testing.allocator, app_config);
    defer std.testing.allocator.free(database_path);
    try std.testing.expectEqualStrings(
        "./data/verso.db",
        database_path,
    );
}

test "resolveDatabasePath keeps absolute SQLite URLs absolute" {
    var app_config = config_types.Config{};
    app_config.database.url = "sqlite:///var/lib/verso.db";

    const database_path = try resolveDatabasePath(std.testing.allocator, app_config);
    defer std.testing.allocator.free(database_path);
    try std.testing.expectEqualStrings(
        "/var/lib/verso.db",
        database_path,
    );
}

test "resolveDatabasePath allocates decoded paths without an incidental size limit" {
    var app_config = config_types.Config{};
    app_config.database.url = "sqlite:///./" ++ ("nested%2F" ** 200) ++ "verso.db";

    const database_path = try resolveDatabasePath(std.testing.allocator, app_config);
    defer std.testing.allocator.free(database_path);
    try std.testing.expect(database_path.len > 1024);
    try std.testing.expectEqual(@as(u8, '.'), database_path[0]);
}
