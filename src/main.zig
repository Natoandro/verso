const std = @import("std");
const clap = @import("clap");
const auth_command = @import("commands/auth.zig");
const config_command = @import("commands/config.zig");
const document_command = @import("commands/document.zig");
const migrate_command = @import("commands/migrate.zig");
const serve_command = @import("commands/serve.zig");

const Command = enum {
    serve,
    config,
    document,
    migrate,
    auth,
};

pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\<command>    Command to run: serve, config, document, migrate, or auth.
        \\
    );
    const parsers = .{
        .command = clap.parsers.enumeration(Command),
    };

    var command_args = try init.minimal.args.iterateAllocator(init.gpa);
    defer command_args.deinit();
    _ = command_args.next();

    var diagnostics = clap.Diagnostic{};
    var parsed_top_level_args = clap.parseEx(clap.Help, &params, parsers, &command_args, .{
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

    switch (parsed_top_level_args.positionals[0] orelse return error.InvalidArguments) {
        .config => return config_command.run(init, &command_args),
        .document => return document_command.run(init, &command_args),
        .migrate => return migrate_command.run(init, &command_args),
        .auth => return auth_command.run(init, &command_args),
        .serve => return serve_command.run(init, &command_args),
    }
}
