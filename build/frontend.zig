const std = @import("std");

pub const Bundle = struct {
    module: *std.Build.Module,
    step: *std.Build.Step,
};

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget) Bundle {
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

    return .{
        .module = b.addModule("editor_assets", .{
            .root_source_file = frontend_output.path(b, "editor_assets.zig"),
            .target = target,
        }),
        .step = &frontend_bundle.step,
    };
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
