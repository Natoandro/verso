const std = @import("std");
const clap = @import("clap");
const verso = @import("verso");
const command_support = @import("support.zig");

pub fn run(init: std.process.Init, command_args: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\
    );

    var diagnostics = clap.Diagnostic{};
    var parsed_args = clap.parseEx(clap.Help, &params, clap.parsers.default, command_args, .{
        .diagnostic = &diagnostics,
        .allocator = init.gpa,
    }) catch |parse_error| {
        try diagnostics.reportToFile(init.io, .stderr(), parse_error);
        return parse_error;
    };
    defer parsed_args.deinit();

    if (parsed_args.args.help != 0) {
        return clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{});
    }

    var parsed_config = verso.config.loadFile(
        init.io,
        init.gpa,
        "verso.toml",
        .{
            .envs = init.environ_map,
            .args = command_args,
        },
    ) catch |configuration_error| {
        command_support.logConfigurationFailure(init, "serve", configuration_error);
        return configuration_error;
    };
    defer parsed_config.deinit();
    const app_config = parsed_config.value;
    return verso.server.run(init.io, init.gpa, app_config);
}
