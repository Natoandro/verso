const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
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

    const mod = b.addModule("verso", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "toml", .module = toml },
            .{ .name = "sqlite", .module = sqlite },
            .{ .name = "embedded_migrations", .module = embedded_migrations },
            .{ .name = "tmpl", .module = tmpl },
        },
    });

    const exe = b.addExecutable(.{
        .name = "verso",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "verso", .module = mod },
                .{ .name = "clap", .module = clap },
            },
        }),
    });

    b.installArtifact(exe);
    b.installDirectory(.{
        .source_dir = b.path("migrations"),
        .install_dir = .prefix,
        .install_subdir = "migrations",
    });

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const malformed_template_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/malformed.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    malformed_template_test.expect_errors = .{ .contains = "unclosed template interpolation" };

    const unknown_template_field_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/unknown_field.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    unknown_template_field_test.expect_errors = .{ .contains = ":?:?: error: unknown field 'titel' in template expression 'post.titel' on unknown_field.Post" };

    const unsupported_template_traversal_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/unsupported_traversal.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    unsupported_template_traversal_test.expect_errors = .{
        .contains = ":?:?: error: template expression 'post.title.length' traverses a non-struct value of type []const u8",
    };

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&malformed_template_test.step);
    test_step.dependOn(&unknown_template_field_test.step);
    test_step.dependOn(&unsupported_template_traversal_test.step);

    const verify_step = b.step("verify", "Verify executable bootstrap flows");
    const verify_command = b.addSystemCommand(&.{ "sh", b.pathFromRoot("test/bootstrap.sh") });
    verify_command.addArtifactArg(exe);
    verify_step.dependOn(&verify_command.step);
}
