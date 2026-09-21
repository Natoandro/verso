const std = @import("std");
const clap = @import("clap");
const verso = @import("verso");
const command_options = @import("options.zig");
const command_support = @import("support.zig");

pub fn run(
    init: std.process.Init,
    command_args: *std.process.Args.Iterator,
    inherited_overrides: verso.config.CliOverrides,
) !void {
    const params = comptime clap.parseParamsComptime(command_options.server_help);

    var diagnostics = clap.Diagnostic{};
    var parsed_args = clap.parseEx(clap.Help, &params, command_options.parsers, command_args, .{
        .diagnostic = &diagnostics,
        .allocator = init.gpa,
    }) catch |parse_error| {
        command_support.logCommandFailure(init, "serve", "argument_parse", "warn", parse_error);
        diagnostics.reportToFile(init.io, .stderr(), parse_error) catch |failure| {
            command_support.logCommandFailure(init, "serve", "argument_diagnostic", "error", failure);
            return failure;
        };
        return parse_error;
    };
    defer parsed_args.deinit();

    if (parsed_args.args.help != 0) {
        return clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{}) catch |failure| {
            command_support.logCommandFailure(init, "serve", "help_output", "error", failure);
            return failure;
        };
    }

    const cli_overrides = command_options.merge(
        inherited_overrides,
        command_options.overrides(parsed_args.args),
    );
    var parsed_config = verso.config.loadFile(
        init.io,
        init.gpa,
        "verso.toml",
        .{
            .envs = init.environ_map,
            .cli = cli_overrides,
        },
    ) catch |configuration_error| {
        command_support.logConfigurationFailure(init, "serve", configuration_error);
        return configuration_error;
    };
    defer parsed_config.deinit();
    const app_config = parsed_config.value;
    command_support.logConfigurationLoaded(init, "serve", app_config, cli_overrides);
    return verso.server.run(init.io, init.gpa, app_config);
}
