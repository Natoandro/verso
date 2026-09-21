const std = @import("std");
const clap = @import("clap");
const verso = @import("verso");
const command_options = @import("options.zig");
const command_support = @import("support.zig");

pub fn run(
    init: std.process.Init,
    command_args: *std.process.Args.Iterator,
    _: verso.config.CliOverrides,
) !void {
    const params = comptime clap.parseParamsComptime(
        command_options.global_help ++ "\n<command>    Configuration command: dump-default or env-reference.\n",
    );

    var diagnostics = clap.Diagnostic{};
    var parsed_args = clap.parseEx(clap.Help, &params, command_options.parsers, command_args, .{
        .diagnostic = &diagnostics,
        .allocator = init.gpa,
    }) catch |parse_error| {
        command_support.logCommandFailure(init, "config", "argument_parse", "warn", parse_error);
        diagnostics.reportToFile(init.io, .stderr(), parse_error) catch |failure| {
            command_support.logCommandFailure(init, "config", "argument_diagnostic", "error", failure);
            return failure;
        };
        return parse_error;
    };
    defer parsed_args.deinit();

    if (parsed_args.args.help != 0) {
        return clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{}) catch |failure| {
            command_support.logCommandFailure(init, "config", "help_output", "error", failure);
            return failure;
        };
    }

    const command_name = parsed_args.positionals[0] orelse {
        command_support.logCommandFailure(init, "config", "command_selection", "warn", error.InvalidArguments);
        return error.InvalidArguments;
    };
    if (std.mem.eql(u8, command_name, "dump-default")) return writeDefaultConfig(init);
    if (std.mem.eql(u8, command_name, "env-reference")) return writeEnvironmentReference(init);
    command_support.logCommandFailure(init, "config", "command_selection", "warn", error.InvalidCommand);
    return error.InvalidCommand;
}

fn writeDefaultConfig(init: std.process.Init) !void {
    var output_buffer: [4096]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    verso.config.Config.writeDefault(&output_writer.interface) catch |failure| {
        command_support.logCommandFailure(init, "config dump-default", "stdout", "error", failure);
        return failure;
    };
    output_writer.flush() catch |failure| {
        command_support.logCommandFailure(init, "config dump-default", "stdout", "error", failure);
        return failure;
    };
}

fn writeEnvironmentReference(init: std.process.Init) !void {
    var output_buffer: [4096]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    output_writer.interface.writeAll(verso.config.environment_reference[0..]) catch |failure| {
        command_support.logCommandFailure(init, "config env-reference", "stdout", "error", failure);
        return failure;
    };
    output_writer.flush() catch |failure| {
        command_support.logCommandFailure(init, "config env-reference", "stdout", "error", failure);
        return failure;
    };
}
