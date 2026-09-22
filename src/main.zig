const std = @import("std");
const clap = @import("clap");
const auth_command = @import("commands/auth.zig");
const config_command = @import("commands/config.zig");
const migrate_command = @import("commands/migrate.zig");
const command_options = @import("commands/options.zig");
const command_support = @import("commands/support.zig");
const serve_command = @import("commands/serve.zig");

pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(command_options.global_help ++ "\n<command>    Command to run: serve, config, migrate, or auth.\n");

    var command_args = try init.minimal.args.iterateAllocator(init.gpa);
    defer command_args.deinit();
    _ = command_args.next();

    var diagnostics = clap.Diagnostic{};
    var parsed_top_level_args = clap.parseEx(clap.Help, &params, command_options.parsers, &command_args, .{
        .diagnostic = &diagnostics,
        .allocator = init.gpa,
        .terminating_positional = 0,
    }) catch |parse_error| {
        command_support.logCommandFailure(init, "verso", "argument_parse", "warn", parse_error);
        diagnostics.reportToFile(init.io, .stderr(), parse_error) catch |failure| {
            command_support.logCommandFailure(init, "verso", "argument_diagnostic", "error", failure);
            return failure;
        };
        return parse_error;
    };
    defer parsed_top_level_args.deinit();

    if (parsed_top_level_args.args.help != 0) {
        return clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{}) catch |failure| {
            command_support.logCommandFailure(init, "verso", "help_output", "error", failure);
            return failure;
        };
    }

    const command_name = parsed_top_level_args.positionals[0] orelse {
        command_support.logCommandFailure(init, "verso", "command_selection", "warn", error.InvalidArguments);
        return error.InvalidArguments;
    };
    const inherited_overrides = command_options.overrides(parsed_top_level_args.args);
    if (std.mem.eql(u8, command_name, "config")) {
        return config_command.run(init, &command_args, inherited_overrides);
    }
    if (std.mem.eql(u8, command_name, "migrate")) {
        return migrate_command.run(init, &command_args, inherited_overrides);
    }
    if (std.mem.eql(u8, command_name, "serve")) {
        return serve_command.run(init, &command_args, inherited_overrides);
    }
    if (std.mem.eql(u8, command_name, "auth")) {
        return auth_command.run(init, &command_args, inherited_overrides);
    }
    command_support.logCommandFailure(init, "verso", "command_selection", "warn", error.InvalidCommand);
    return error.InvalidCommand;
}
