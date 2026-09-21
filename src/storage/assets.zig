const std = @import("std");

pub const checksum_hex_length = std.crypto.hash.sha2.Sha256.digest_length * 2;

pub const StoredObject = struct {
    checksum_sha256: [checksum_hex_length]u8,
    object_key: []const u8,
    byte_size: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *StoredObject) void {
        self.allocator.free(self.object_key);
        self.* = undefined;
    }
};

/// The asset store owns the opened directories passed to or created by it.
/// Its object directory is deliberately separate from any configured public
/// static directory; public delivery must go through an authorization-aware
/// application handler.
pub const Store = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    objects: std.Io.Dir,

    pub fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        root_path: []const u8,
    ) !Store {
        const root = if (std.fs.path.isAbsolute(root_path))
            try std.Io.Dir.openDirAbsolute(io, root_path, .{ .access_sub_paths = true, .follow_symlinks = false })
        else
            try std.Io.Dir.cwd().openDir(io, root_path, .{ .access_sub_paths = true, .follow_symlinks = false });
        errdefer root.close(io);
        return try init(io, allocator, root);
    }

    /// Takes ownership of `root`; callers must not close it after this call.
    pub fn init(io: std.Io, allocator: std.mem.Allocator, root: std.Io.Dir) !Store {
        errdefer root.close(io);
        try root.createDirPath(io, "objects");
        const objects = try root.openDir(io, "objects", .{
            .iterate = true,
            .access_sub_paths = true,
            .follow_symlinks = false,
        });
        return .{
            .io = io,
            .allocator = allocator,
            .root = root,
            .objects = objects,
        };
    }

    pub fn deinit(self: *Store) void {
        self.objects.close(self.io);
        self.root.close(self.io);
        self.* = undefined;
    }

    pub fn put(self: *Store, content: []const u8, extension: []const u8) !StoredObject {
        try validateExtension(extension);

        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
        const checksum = std.fmt.bytesToHex(digest, .lower);
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ checksum, extension });
        defer self.allocator.free(filename);
        const object_key = try std.fmt.allocPrint(self.allocator, "objects/{s}", .{filename});
        errdefer self.allocator.free(object_key);

        var temporary = try self.objects.createFileAtomic(self.io, filename, .{});
        defer temporary.deinit(self.io);
        try temporary.file.writeStreamingAll(self.io, content);
        try temporary.file.sync(self.io);
        temporary.link(self.io) catch |link_error| switch (link_error) {
            error.PathAlreadyExists => try self.verifyExisting(filename, content),
            else => return link_error,
        };

        return .{
            .checksum_sha256 = checksum,
            .object_key = object_key,
            .byte_size = content.len,
            .allocator = self.allocator,
        };
    }

    fn verifyExisting(self: *Store, filename: []const u8, expected: []const u8) !void {
        var file = self.objects.openFile(self.io, filename, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |open_error| switch (open_error) {
            error.FileNotFound => return error.ObjectConflict,
            else => return open_error,
        };
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        if (stat.kind != .file or stat.size != expected.len) return error.ObjectConflict;
        var reader = file.reader(self.io, &.{});
        const actual = try reader.interface.allocRemaining(self.allocator, .limited(expected.len + 1));
        defer self.allocator.free(actual);
        if (!std.mem.eql(u8, actual, expected)) return error.ObjectConflict;
    }
};

fn validateExtension(extension: []const u8) !void {
    if (extension.len == 0 or extension.len > 32) return error.InvalidExtension;
    for (extension) |character| {
        if (!std.ascii.isAlphanumeric(character)) return error.InvalidExtension;
    }
}

fn openTestStore(temporary_directory: *std.testing.TmpDir) !Store {
    try temporary_directory.dir.createDirPath(std.testing.io, "assets");
    const asset_directory = try temporary_directory.dir.openDir(std.testing.io, "assets", .{});
    return Store.init(std.testing.io, std.testing.allocator, asset_directory);
}

test "asset store writes content-addressed objects atomically and deduplicates" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var store = try openTestStore(&temporary_directory);
    defer store.deinit();

    var first = try store.put("asset bytes", "png");
    defer first.deinit();
    try std.testing.expectEqual(@as(u64, 11), first.byte_size);
    try std.testing.expectEqualStrings(
        "objects/84293ed06cb3210e7d549afec3140d0c48494416ad25b7f25196afffaa5eb796.png",
        first.object_key,
    );

    var second = try store.put("asset bytes", "png");
    defer second.deinit();
    try std.testing.expectEqualStrings(first.object_key, second.object_key);

    var iterator = store.objects.iterate();
    var entries: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        entries += 1;
        try std.testing.expectEqual(.file, entry.kind);
    }
    try std.testing.expectEqual(@as(usize, 1), entries);
}

test "asset store rejects unsafe extensions before writing" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var store = try openTestStore(&temporary_directory);
    defer store.deinit();

    try std.testing.expectError(error.InvalidExtension, store.put("asset", "../png"));
    try std.testing.expectError(error.InvalidExtension, store.put("asset", "png/"));
}

test "asset store preserves an existing object on content conflict" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var store = try openTestStore(&temporary_directory);
    defer store.deinit();

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("original", &digest, .{});
    const checksum = std.fmt.bytesToHex(digest, .lower);
    const filename = try std.fmt.allocPrint(std.testing.allocator, "{s}.bin", .{checksum});
    defer std.testing.allocator.free(filename);
    try store.objects.writeFile(std.testing.io, .{ .sub_path = filename, .data = "tampered" });

    try std.testing.expectError(error.ObjectConflict, store.put("original", "bin"));
    var file = try store.objects.openFile(std.testing.io, filename, .{ .allow_directory = false });
    defer file.close(std.testing.io);
    var reader = file.reader(std.testing.io, &.{});
    const actual = try reader.interface.allocRemaining(std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("tampered", actual);
}
