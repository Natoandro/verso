const std = @import("std");
const config = @import("config.zig");

pub fn prepareDirectories(io: std.Io, root: std.Io.Dir, value: config.Config) !void {
    var database_path_buffer: [1024]u8 = undefined;
    const database_path = try databasePath(value, &database_path_buffer);
    try createParentPath(io, root, database_path);

    switch (value.storage) {
        .filesystem => |filesystem| try root.createDirPath(io, filesystem.path),
    }
    try root.createDirPath(io, value.cache.path);
}

pub fn serve(io: std.Io, value: config.Config) !void {
    try prepareDirectories(io, std.Io.Dir.cwd(), value);

    var address = try resolveAddress(io, value.server.host, value.server.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    while (true) {
        var stream = try server.accept(io);
        defer stream.close(io);

        var read_buffer: [8192]u8 = undefined;
        var write_buffer: [8192]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);
        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http_server.receiveHead() catch continue;
        try request.respond("Verso is running\n", .{
            .keep_alive = false,
            .extra_headers = &.{.{
                .name = "content-type",
                .value = "text/plain; charset=utf-8",
            }},
        });
    }
}

fn resolveAddress(io: std.Io, host: []const u8, port: u16) !std.Io.net.IpAddress {
    if (std.Io.net.IpAddress.parse(host, port)) |address| return address else |_| {}

    var host_name = try std.Io.net.HostName.init(host);
    var lookup_buffer: [32]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    try host_name.lookup(io, &lookup_queue, .{ .port = port });

    while (lookup_queue.getOneUncancelable(io)) |result| {
        switch (result) {
            .address => |address| return address,
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Closed => return error.NoAddressReturned,
    }
}

fn databasePath(value: config.Config, buffer: []u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, value.database.url, ':') == null) {
        return value.database.url;
    }

    const uri = try std.Uri.parse(value.database.url);
    if (!uri.path.isEmpty()) return uri.path.toRaw(buffer);
    if (uri.host) |host| return host.toRaw(buffer);
    return error.InvalidDatabaseUrl;
}

fn createParentPath(io: std.Io, root: std.Io.Dir, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try root.createDirPath(io, parent);
}

test "prepareDirectories creates database, asset, and cache parents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var value = config.Config{};
    value.database.url = "nested/db/verso.db";
    value.storage = .{ .filesystem = .{ .path = "nested/assets" } };
    value.cache.path = "nested/cache";

    try prepareDirectories(std.testing.io, tmp.dir, value);

    var database_parent = try tmp.dir.openDir(std.testing.io, "nested/db", .{});
    database_parent.close(std.testing.io);
    var assets = try tmp.dir.openDir(std.testing.io, "nested/assets", .{});
    assets.close(std.testing.io);
    var cache = try tmp.dir.openDir(std.testing.io, "nested/cache", .{});
    cache.close(std.testing.io);
}

test "prepareDirectories is repeatable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const value = config.Config{};
    try prepareDirectories(std.testing.io, tmp.dir, value);
    try prepareDirectories(std.testing.io, tmp.dir, value);
}
