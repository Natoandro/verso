const std = @import("std");

pub fn resolveMigrationDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    configured_path: []const u8,
) ![]u8 {
    var directory = std.Io.Dir.cwd().openDir(io, configured_path, .{}) catch |path_error| switch (path_error) {
        error.FileNotFound => null,
        else => return path_error,
    };
    if (directory) |*directory_handle| {
        directory_handle.close(io);
        return allocator.dupe(u8, configured_path);
    }

    if (!std.mem.eql(u8, configured_path, "migrations")) return error.FileNotFound;

    const executable_directory = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_directory);
    const install_prefix = std.fs.path.dirname(executable_directory) orelse return error.InvalidExecutablePath;
    return std.fs.path.join(allocator, &.{ install_prefix, "migrations" });
}
