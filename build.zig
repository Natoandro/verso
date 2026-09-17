const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const frontend_bundle = b.addSystemCommand(&.{ "node", b.pathFromRoot("web-editor/build.mjs") });
    const frontend_output = frontend_bundle.addPrefixedOutputDirectoryArg("--out-dir=", "editor-assets");
    const frontend_config_inputs = [_][]const u8{
        "web-editor/build.mjs",
        "web-editor/package.json",
        "web-editor/pnpm-lock.yaml",
        "web-editor/tsconfig.json",
        "web-editor/vite.config.ts",
    };
    for (frontend_config_inputs) |input| frontend_bundle.addFileInput(b.path(input));
    addDirectoryFileInputs(b, frontend_bundle, "web-editor/src");
    addDirectoryFileInputs(b, frontend_bundle, "web-editor/test");
    const editor_assets = b.addModule("editor_assets", .{
        .root_source_file = frontend_output.path(b, "editor_assets.zig"),
        .target = target,
    });
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
            .{ .name = "editor_assets", .module = editor_assets },
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
    exe.step.dependOn(&frontend_bundle.step);

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

    const invalid_template_condition_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/invalid_condition.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    invalid_template_condition_test.expect_errors = .{
        .contains = ":?:?: error: template if condition must be bool or optional, got *const [15:0]u8",
    };

    const invalid_template_iteration_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/invalid_iteration.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    invalid_template_iteration_test.expect_errors = .{
        .contains = ":?:?: error: template for requires an array or slice, got *const [12:0]u8",
    };

    const malformed_template_capture_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/malformed_capture.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    malformed_template_capture_test.expect_errors = .{
        .contains = "for directive requires a closing capture bar",
    };

    const unmatched_template_block_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/unmatched_block.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    unmatched_template_block_test.expect_errors = .{
        .contains = "unclosed template if block",
    };

    const leaked_template_capture_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/capture_scope.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    leaked_template_capture_test.expect_errors = .{
        .contains = ":?:?: error: unknown field 'item' in template expression 'item.name' on capture_scope.Context",
    };

    const malformed_if_capture_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/malformed_if_capture.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    malformed_if_capture_test.expect_errors = .{
        .contains = "if directive has malformed capture syntax",
    };

    const malformed_for_capture_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/malformed_for_capture.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    malformed_for_capture_test.expect_errors = .{
        .contains = "for directive has malformed capture syntax",
    };

    const unexpected_template_closer_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/unexpected_closer.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    unexpected_template_closer_test.expect_errors = .{
        .contains = "unexpected template if closer",
    };

    const mismatched_template_closer_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/mismatched_closer.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    mismatched_template_closer_test.expect_errors = .{
        .contains = "unexpected template for closer",
    };

    const duplicate_template_else_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/duplicate_else.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    duplicate_template_else_test.expect_errors = .{
        .contains = "unclosed template if block",
    };

    const unknown_template_component_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/unknown_component.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    unknown_template_component_test.expect_errors = .{
        .contains = "unknown template component 'missing'",
    };

    const missing_template_component_argument_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/missing_component_argument.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    missing_template_component_argument_test.expect_errors = .{
        .contains = "missing argument 'user' for component 'card'",
    };

    const invalid_template_component_argument_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/invalid_component_argument.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    invalid_template_component_argument_test.expect_errors = .{
        .contains = "template expression 'user.name' traverses a non-struct value of type i64",
    };

    const duplicate_template_snippet_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/duplicate_snippet.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    duplicate_template_snippet_test.expect_errors = .{
        .contains = "duplicate snippet name 'card' in the same scope",
    };

    const malformed_template_snippet_parameters_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/malformed_snippet_parameters.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    malformed_template_snippet_parameters_test.expect_errors = .{
        .contains = "snippet declarations have malformed parameters",
    };

    const duplicate_template_snippet_parameter_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/duplicate_snippet_parameter.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    duplicate_template_snippet_parameter_test.expect_errors = .{
        .contains = "duplicate snippet parameter 'value'",
    };

    const missing_template_snippet_argument_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/missing_snippet_argument.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    missing_template_snippet_argument_test.expect_errors = .{
        .contains = "missing arguments for snippet 'card'",
    };

    const missing_positional_template_snippet_argument_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/missing_positional_snippet_argument.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    missing_positional_template_snippet_argument_test.expect_errors = .{
        .contains = "missing arguments for snippet 'card'",
    };

    const mixed_template_snippet_arguments_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/mixed_snippet_arguments.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    mixed_template_snippet_arguments_test.expect_errors = .{
        .contains = "cannot mix positional and named arguments",
    };

    const excess_template_snippet_argument_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/excess_snippet_arguments.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    excess_template_snippet_argument_test.expect_errors = .{
        .contains = "too many arguments for snippet 'card'",
    };

    const unknown_template_snippet_argument_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/unknown_snippet_argument.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    unknown_template_snippet_argument_test.expect_errors = .{
        .contains = "unknown argument 'other' for snippet 'card'",
    };

    const duplicate_template_snippet_argument_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/duplicate_snippet_argument.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    duplicate_template_snippet_argument_test.expect_errors = .{
        .contains = "duplicate argument 'value' for snippet 'card'",
    };

    const snippet_visibility_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/snippet_visibility.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    snippet_visibility_test.expect_errors = .{
        .contains = "unknown template component 'inner'",
    };

    const snippet_isolation_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/snippet_isolation.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    snippet_isolation_test.expect_errors = .{
        .contains = ":?:?: error: unknown field 'title' in template expression 'title' on render.EmptyContext",
    };

    const missing_layout_slot_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compile_failures/missing_layout_slot.zig"),
            .target = target,
            .imports = &.{.{ .name = "tmpl", .module = tmpl }},
        }),
    });
    missing_layout_slot_test.expect_errors = .{
        .contains = "unknown template component 'footer'",
    };

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&malformed_template_test.step);
    test_step.dependOn(&unknown_template_field_test.step);
    test_step.dependOn(&unsupported_template_traversal_test.step);
    test_step.dependOn(&invalid_template_condition_test.step);
    test_step.dependOn(&invalid_template_iteration_test.step);
    test_step.dependOn(&malformed_template_capture_test.step);
    test_step.dependOn(&unmatched_template_block_test.step);
    test_step.dependOn(&leaked_template_capture_test.step);
    test_step.dependOn(&malformed_if_capture_test.step);
    test_step.dependOn(&malformed_for_capture_test.step);
    test_step.dependOn(&unexpected_template_closer_test.step);
    test_step.dependOn(&mismatched_template_closer_test.step);
    test_step.dependOn(&duplicate_template_else_test.step);
    test_step.dependOn(&unknown_template_component_test.step);
    test_step.dependOn(&missing_template_component_argument_test.step);
    test_step.dependOn(&invalid_template_component_argument_test.step);
    test_step.dependOn(&duplicate_template_snippet_test.step);
    test_step.dependOn(&malformed_template_snippet_parameters_test.step);
    test_step.dependOn(&duplicate_template_snippet_parameter_test.step);
    test_step.dependOn(&missing_template_snippet_argument_test.step);
    test_step.dependOn(&missing_positional_template_snippet_argument_test.step);
    test_step.dependOn(&mixed_template_snippet_arguments_test.step);
    test_step.dependOn(&excess_template_snippet_argument_test.step);
    test_step.dependOn(&unknown_template_snippet_argument_test.step);
    test_step.dependOn(&duplicate_template_snippet_argument_test.step);
    test_step.dependOn(&snippet_visibility_test.step);
    test_step.dependOn(&snippet_isolation_test.step);
    test_step.dependOn(&missing_layout_slot_test.step);
    test_step.dependOn(&frontend_bundle.step);
    const frontend_check = b.addSystemCommand(&.{ "corepack", "pnpm", "--dir", b.pathFromRoot("web-editor"), "check" });
    test_step.dependOn(&frontend_check.step);
    const frontend_tests = b.addSystemCommand(&.{ "corepack", "pnpm", "--dir", b.pathFromRoot("web-editor"), "test" });
    test_step.dependOn(&frontend_tests.step);

    const verify_step = b.step("verify", "Verify executable bootstrap flows");
    const verify_command = b.addSystemCommand(&.{ "sh", b.pathFromRoot("test/bootstrap.sh") });
    verify_command.addArtifactArg(exe);
    verify_step.dependOn(&verify_command.step);
}

fn addDirectoryFileInputs(b: *std.Build, run: *std.Build.Step.Run, sub_path: []const u8) void {
    var directory = std.Io.Dir.cwd().openDir(b.graph.io, sub_path, .{ .iterate = true }) catch |err| {
        @panic(b.fmt("unable to open frontend input directory '{s}': {t}", .{ sub_path, err }));
    };
    defer directory.close(b.graph.io);

    var walker = directory.walk(b.allocator) catch |err| {
        @panic(b.fmt("unable to walk frontend input directory '{s}': {t}", .{ sub_path, err }));
    };
    defer walker.deinit();

    while (walker.next(b.graph.io) catch |err| {
        @panic(b.fmt("unable to enumerate frontend input directory '{s}': {t}", .{ sub_path, err }));
    }) |entry| {
        if (entry.kind != .file) continue;
        run.addFileInput(b.path(b.pathJoin(&.{ sub_path, entry.path })));
    }
}
