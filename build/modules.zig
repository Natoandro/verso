const std = @import("std");

pub const ProjectModules = struct {
    verso: *std.Build.Module,
    clap: *std.Build.Module,
    tmpl: *std.Build.Module,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ProjectModules {
    const toml = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    }).module("toml");
    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    }).module("clap");
    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    }).module("sqlite");
    const embedded_migrations = b.addModule("embedded_migrations", .{
        .root_source_file = b.path("src/migrations/embedded.zig"),
        .target = target,
    });
    const tmpl = b.addModule("tmpl", .{
        .root_source_file = b.path("src/template/root.zig"),
        .target = target,
    });
    const verso = b.addModule("verso", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "toml", .module = toml },
            .{ .name = "sqlite", .module = sqlite },
            .{ .name = "embedded_migrations", .module = embedded_migrations },
            .{ .name = "tmpl", .module = tmpl },
        },
    });

    return .{
        .verso = verso,
        .clap = clap,
        .tmpl = tmpl,
    };
}
