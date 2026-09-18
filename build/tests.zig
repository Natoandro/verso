const std = @import("std");
const application = @import("application.zig");
const project = @import("modules.zig");

const CompileFailure = struct {
    directory: []const u8 = "src/template/compile_failures",
    source: []const u8,
    message: []const u8,
};

const compile_failures = [_]CompileFailure{
    .{ .source = "malformed.zig", .message = "unclosed template interpolation" },
    .{ .source = "unknown_field.zig", .message = ":?:?: error: unknown field 'titel' in template expression 'post.titel' on unknown_field.Post" },
    .{ .source = "unsupported_traversal.zig", .message = ":?:?: error: template expression 'post.title.length' traverses a non-struct value of type []const u8" },
    .{ .source = "invalid_condition.zig", .message = ":?:?: error: template if condition must be bool or optional, got *const [15:0]u8" },
    .{ .source = "invalid_iteration.zig", .message = ":?:?: error: template for requires an array or slice, got *const [12:0]u8" },
    .{ .source = "malformed_capture.zig", .message = "for directive requires a closing capture bar" },
    .{ .source = "unmatched_block.zig", .message = "unclosed template if block" },
    .{ .source = "capture_scope.zig", .message = ":?:?: error: unknown field 'item' in template expression 'item.name' on capture_scope.Context" },
    .{ .source = "malformed_if_capture.zig", .message = "if directive has malformed capture syntax" },
    .{ .source = "malformed_for_capture.zig", .message = "for directive has malformed capture syntax" },
    .{ .source = "unexpected_closer.zig", .message = "unexpected template if closer" },
    .{ .source = "mismatched_closer.zig", .message = "unexpected template for closer" },
    .{ .source = "duplicate_else.zig", .message = "unclosed template if block" },
    .{ .source = "unknown_component.zig", .message = "unknown template component 'missing'" },
    .{ .source = "missing_component_argument.zig", .message = "missing argument 'user' for component 'card'" },
    .{ .source = "invalid_component_argument.zig", .message = "template expression 'user.name' traverses a non-struct value of type i64" },
    .{ .source = "duplicate_snippet.zig", .message = "duplicate snippet name 'card' in the same scope" },
    .{ .source = "malformed_snippet_parameters.zig", .message = "snippet declarations have malformed parameters" },
    .{ .source = "duplicate_snippet_parameter.zig", .message = "duplicate snippet parameter 'value'" },
    .{ .source = "missing_snippet_argument.zig", .message = "missing arguments for snippet 'card'" },
    .{ .source = "missing_positional_snippet_argument.zig", .message = "missing arguments for snippet 'card'" },
    .{ .source = "mixed_snippet_arguments.zig", .message = "cannot mix positional and named arguments" },
    .{ .source = "excess_snippet_arguments.zig", .message = "too many arguments for snippet 'card'" },
    .{ .source = "unknown_snippet_argument.zig", .message = "unknown argument 'other' for snippet 'card'" },
    .{ .source = "duplicate_snippet_argument.zig", .message = "duplicate argument 'value' for snippet 'card'" },
    .{ .source = "snippet_visibility.zig", .message = "unknown template component 'inner'" },
    .{ .source = "snippet_isolation.zig", .message = ":?:?: error: unknown field 'title' in template expression 'title' on render.EmptyContext" },
    .{ .source = "missing_layout_slot.zig", .message = "unknown template component 'footer'" },
    .{ .directory = "src", .source = "malformed_route_compile_failure.zig", .message = ":?:?: error: malformed route pattern 'GET /articles/{id': malformed parameter" },
    .{ .directory = "src", .source = "duplicate_route_parameter_compile_failure.zig", .message = ":?:?: error: duplicate route parameter 'id' in pattern 'GET /articles/{id}/{id}'" },
    .{ .directory = "src", .source = "wildcard_route_compile_failure.zig", .message = ":?:?: error: trailing wildcard is reserved and not enabled in route pattern 'GET /assets/{path...}'" },
    .{ .directory = "src", .source = "ambiguous_routes_compile_failure.zig", .message = ":?:?: error: ambiguous route declarations 'GET /articles/{id}' and 'GET /articles/{slug}'" },
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    modules: project.ProjectModules,
    app: application.Application,
) void {
    const test_step = b.step("test", "Run tests");
    const mod_tests = b.addTest(.{ .root_module = modules.verso });
    const exe_tests = b.addTest(.{ .root_module = app.executable.root_module });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    for (compile_failures) |failure| {
        const compile_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.pathJoin(&.{ failure.directory, failure.source })),
                .target = target,
                .imports = &.{.{ .name = "tmpl", .module = modules.tmpl }},
            }),
        });
        compile_test.expect_errors = .{ .contains = failure.message };
        test_step.dependOn(&compile_test.step);
    }

    const verify_step = b.step("verify", "Verify executable bootstrap flows");
    const verify_command = b.addSystemCommand(&.{ "sh", b.pathFromRoot("test/bootstrap.sh") });
    verify_command.addArtifactArg(app.executable);
    verify_step.dependOn(&verify_command.step);
}
