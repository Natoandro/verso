const std = @import("std");
const clap = @import("clap");
const verso = @import("verso");
const command_options = @import("options.zig");

pub fn run(
    init: std.process.Init,
    command_args: *std.process.Args.Iterator,
    _: verso.config.CliOverrides,
) !void {
    const params = comptime clap.parseParamsComptime(command_options.global_help ++ "\n<command>    Configuration command: dump-default.\n");

    var diagnostics = clap.Diagnostic{};
    var parsed_args = clap.parseEx(clap.Help, &params, command_options.parsers, command_args, .{
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

    const command_name = parsed_args.positionals[0] orelse return error.InvalidArguments;
    if (std.mem.eql(u8, command_name, "dump-default")) return writeDefaultConfig(init.io);
    return error.InvalidCommand;
}

fn writeDefaultConfig(io: std.Io) !void {
    var output_buffer: [4096]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(io, &output_buffer);
    try verso.config.Config.writeDefault(&output_writer.interface);
    try output_writer.flush();
}
