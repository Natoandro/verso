const std = @import("std");
const project = @import("modules.zig");

pub const Application = struct {
    executable: *std.Build.Step.Compile,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: project.ProjectModules,
) Application {
    const executable = b.addExecutable(.{
        .name = "verso",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "verso", .module = modules.verso },
                .{ .name = "clap", .module = modules.clap },
            },
        }),
    });
    return .{
        .executable = executable,
    };
}
