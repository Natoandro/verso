const std = @import("std");
const sqlite = @import("sqlite");
const migrations = @import("migrations.zig");

pub const Database = struct {
    handle: sqlite.Db,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var database = Database{ .handle = try sqlite.Db.init(.{
            .mode = .{ .File = path_z },
            .open_flags = .{ .write = true, .create = true },
            .threading_mode = .Serialized,
        }) };
        errdefer database.close();

        try database.configureConnection();
        return database;
    }

    pub fn migrateUp(
        self: *Database,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !usize {
        const directory_path = try migrations.runtimeDirectoryPath(io, allocator);
        defer allocator.free(directory_path);
        return migrations.migrateUp(&self.handle, io, allocator, directory_path);
    }

    pub fn close(self: *Database) void {
        self.handle.deinit();
        self.* = undefined;
    }

    fn configureConnection(self: *Database) !void {
        const journal_mode = try self.handle.pragma([16:0]u8, .{}, "journal_mode", "WAL") orelse return error.InvalidJournalMode;
        if (!std.ascii.eqlIgnoreCase(journal_mode[0..3], "wal") or journal_mode[3] != 0) return error.InvalidJournalMode;

        try self.handle.exec("PRAGMA synchronous = NORMAL", .{}, .{});
        try self.handle.exec("PRAGMA foreign_keys = ON", .{}, .{});
        const foreign_keys = try self.handle.pragma(i64, .{}, "foreign_keys", null) orelse return error.ForeignKeysDisabled;
        if (foreign_keys != 1) return error.ForeignKeysDisabled;

        const busy_timeout = try self.handle.pragma(i64, .{}, "busy_timeout", "5000") orelse return error.InvalidBusyTimeout;
        if (busy_timeout != 5000) return error.InvalidBusyTimeout;
    }
};
