const std = @import("std");
const sqlite = @import("sqlite");

pub const Database = struct {
    handle: sqlite.Db,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        return .{ .handle = try sqlite.Db.init(.{
            .mode = .{ .File = path_z },
            .open_flags = .{ .write = true, .create = true },
            .threading_mode = .Serialized,
        }) };
    }

    pub fn close(self: *Database) void {
        self.handle.deinit();
        self.* = undefined;
    }
};

test "opens and closes a SQLite database" {
    var db = try Database.open(std.testing.allocator, ":memory:");
    db.close();
}
