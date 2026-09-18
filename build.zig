const std = @import("std");
const application = @import("build/application.zig");
const frontend = @import("build/frontend.zig");
const modules = @import("build/modules.zig");
const tests = @import("build/tests.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip symbols from the executable") orelse false;

    const editor = frontend.add(b, target);
    const project_modules = modules.add(b, target, optimize, editor.module);
    const app = application.add(b, target, optimize, project_modules);
    app.executable.step.dependOn(editor.step);

    app.executable.root_module.strip = strip;
    b.installArtifact(app.executable);
    b.installDirectory(.{
        .source_dir = b.path("migrations"),
        .install_dir = .prefix,
        .install_subdir = "migrations",
    });

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(app.executable);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    tests.add(b, target, project_modules, app, editor.step);
}
