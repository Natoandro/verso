const std = @import("std");
const clap = @import("clap");
const verso = @import("verso");
const logging = verso.logging;

const Command = enum {
    serve,
    config,
};

const ConfigCommand = enum {
    dump_default,
};

pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\<command>    Command to run: serve or config.
        \\
    );
    const parsers = .{
        .command = clap.parsers.enumeration(Command),
    };

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();

    var diag = clap.Diagnostic{};
    var parsed = clap.parseEx(clap.Help, &params, parsers, &args, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
        .terminating_positional = 0,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer parsed.deinit();

    if (parsed.args.help != 0) {
        return clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{});
    }

    switch (parsed.positionals[0] orelse return error.InvalidArguments) {
        .config => return configCommand(init.io, init.gpa, &args),
        .serve => return serveCommand(init, &args),
    }
}

fn serveCommand(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\
    );

    var diag = clap.Diagnostic{};
    var parsed = clap.parseEx(clap.Help, &params, clap.parsers.default, args, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer parsed.deinit();

    if (parsed.args.help != 0) {
        return clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{});
    }

    var loaded_config = verso.config.loadFile(
        init.io,
        init.gpa,
        "verso.toml",
        .{
            .envs = init.environ_map,
            .args = args,
        },
    ) catch |err| {
        logConfigurationFailure(init, err);
        return err;
    };
    defer loaded_config.deinit();
    return verso.runtime.serve(init.io, init.gpa, loaded_config.value);
}

fn logConfigurationFailure(init: std.process.Init, err: anyerror) void {
    const stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false;
    var logger = logging.Logger.initWithOptions(
        init.gpa,
        if (stderr_is_tty) .pretty else .text,
        .{ .use_color = stderr_is_tty, .omit_null_fields = true },
    );
    logger.log(init.io, .{
        .level = "error",
        .event = "configuration.failed",
        .message = "configuration failed",
        .command = "serve",
        .error_name = @errorName(err),
    }) catch {};
}

fn configCommand(io: std.Io, allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\<command>    Configuration command: dump-default.
        \\
    );
    const parsers = .{
        .command = parseConfigCommand,
    };

    var diag = clap.Diagnostic{};
    var parsed = clap.parseEx(clap.Help, &params, parsers, args, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer parsed.deinit();

    if (parsed.args.help != 0) {
        return clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
    }

    switch (parsed.positionals[0] orelse return error.InvalidArguments) {
        .dump_default => return dumpDefaultConfig(io),
    }
}

fn parseConfigCommand(value: []const u8) error{InvalidCommand}!ConfigCommand {
    if (std.mem.eql(u8, value, "dump-default")) return .dump_default;
    return error.InvalidCommand;
}

fn dumpDefaultConfig(io: std.Io) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try verso.config.Config.writeDefault(&writer.interface);
    try writer.flush();
}
