const std = @import("std");
const clap = @import("clap");
const verso = @import("verso");
const logging = verso.logging;

const Command = enum {
    serve,
    config,
    migrate,
};

const ConfigCommand = enum {
    dump_default,
};

const MigrateCommand = enum {
    up,
};

pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\<command>    Command to run: serve, config, or migrate.
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
        .migrate => return migrateCommand(init, &args),
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
        logConfigurationFailure(init, "serve", err);
        return err;
    };
    defer loaded_config.deinit();
    return verso.runtime.serve(init.io, init.gpa, loaded_config.value);
}

fn logConfigurationFailure(init: std.process.Init, command: []const u8, err: anyerror) void {
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
        .command = command,
        .error_name = @errorName(err),
    }) catch {};
}

fn migrateCommand(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\<command>    Migration command: up.
        \\
    );
    const parsers = .{ .command = clap.parsers.enumeration(MigrateCommand) };

    var diag = clap.Diagnostic{};
    var parsed = clap.parseEx(clap.Help, &params, parsers, args, .{
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

    switch (parsed.positionals[0] orelse return error.InvalidArguments) {
        .up => try migrateUp(init),
    }
}

fn migrateUp(init: std.process.Init) !void {
    var loaded_config = verso.config.loadFile(
        init.io,
        init.gpa,
        "verso.toml",
        .{ .envs = init.environ_map },
    ) catch |err| {
        logConfigurationFailure(init, "migrate up", err);
        return err;
    };
    defer loaded_config.deinit();

    try verso.runtime.prepareDatabaseDirectory(init.io, std.Io.Dir.cwd(), loaded_config.value);
    var database_path_buffer: [1024]u8 = undefined;
    const database_path = try verso.runtime.databasePath(loaded_config.value, &database_path_buffer);
    var database = try verso.storage.sqlite.Database.open(init.gpa, database_path);
    defer database.close();

    const stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false;
    var logger = logging.Logger.initWithOptions(
        init.gpa,
        loaded_config.value.effectiveLoggingFormat(stderr_is_tty),
        .{
            .use_color = stderr_is_tty,
            .omit_null_fields = loaded_config.value.logging.omit_null_fields,
        },
    );
    const migration_directory = try verso.storage.migration_directory.resolveMigrationDirectory(
        init.io,
        init.gpa,
        loaded_config.value.migrations.path,
    );
    defer init.gpa.free(migration_directory);
    var migration_context = database.migrationContext(
        init.io,
        init.gpa,
        migration_directory,
        &logger,
    );
    const applied = try migration_context.migrateUp();
    var buffer: [128]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    if (applied == 0) {
        try writer.interface.writeAll("Database is up to date.\n");
    } else {
        try writer.interface.print("Applied {d} migration{s}.\n", .{ applied, if (applied == 1) "" else "s" });
    }
    try writer.flush();
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
