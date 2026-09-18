const std = @import("std");
const clap = @import("clap");
const auth_command = @import("commands/auth.zig");
const config_command = @import("commands/config.zig");
const document_command = @import("commands/document.zig");
const migrate_command = @import("commands/migrate.zig");
const command_options = @import("commands/options.zig");
const serve_command = @import("commands/serve.zig");

pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(command_options.global_help ++ "\n<command>    Command to run: serve, config, document, migrate, or auth.\n");

    var command_args = try init.minimal.args.iterateAllocator(init.gpa);
    defer command_args.deinit();
    _ = command_args.next();

    var diagnostics = clap.Diagnostic{};
    var parsed_top_level_args = clap.parseEx(clap.Help, &params, command_options.parsers, &command_args, .{
        .diagnostic = &diagnostics,
        .allocator = init.gpa,
        .terminating_positional = 0,
    }) catch |parse_error| {
        try diagnostics.reportToFile(init.io, .stderr(), parse_error);
        return parse_error;
    };
    defer parsed_top_level_args.deinit();

    if (parsed_top_level_args.args.help != 0) {
        return clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{});
    }

    const command_name = parsed_top_level_args.positionals[0] orelse return error.InvalidArguments;
    const inherited_overrides = command_options.overrides(parsed_top_level_args.args);
    if (std.mem.eql(u8, command_name, "config")) {
        return config_command.run(init, &command_args, inherited_overrides);
    }
    if (std.mem.eql(u8, command_name, "document")) {
        return document_command.run(init, &command_args, inherited_overrides);
    }
    if (std.mem.eql(u8, command_name, "migrate")) {
        return migrate_command.run(init, &command_args, inherited_overrides);
    }
    if (std.mem.eql(u8, command_name, "serve")) {
        return serve_command.run(init, &command_args, inherited_overrides);
    }
    if (std.mem.eql(u8, command_name, "auth")) {
        return auth_command.run(init, &command_args);
    }
    return error.InvalidCommand;
}
