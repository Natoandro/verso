const std = @import("std");
const clap = @import("clap");
const verso = @import("verso");
const logging = verso.logging;
const command_options = @import("options.zig");
const command_support = @import("support.zig");

pub fn run(
    init: std.process.Init,
    command_args: *std.process.Args.Iterator,
    inherited_overrides: verso.config.CliOverrides,
) !void {
    const params = comptime clap.parseParamsComptime(command_options.migration_help ++ "\n<command>    Migration command: up.\n");

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
    if (!std.mem.eql(u8, command_name, "up")) return error.InvalidCommand;
    try runUp(init, command_options.merge(
        inherited_overrides,
        command_options.overrides(parsed_args.args),
    ));
}

fn runUp(init: std.process.Init, cli_overrides: verso.config.CliOverrides) !void {
    var parsed_config = verso.config.loadFile(
        init.io,
        init.gpa,
        "verso.toml",
        .{ .envs = init.environ_map, .cli = cli_overrides },
    ) catch |configuration_error| {
        command_support.logConfigurationFailure(init, "migrate up", configuration_error);
        return configuration_error;
    };
    defer parsed_config.deinit();
    const app_config = parsed_config.value;
    command_support.logConfigurationLoaded(init, "migrate up", app_config, cli_overrides);

    try verso.application.bootstrap.prepareDatabaseParentDirectory(
        init.io,
        std.Io.Dir.cwd(),
        app_config,
    );
    var database_path_buffer: [1024]u8 = undefined;
    const database_path = try verso.application.bootstrap.resolveDatabasePath(
        app_config,
        &database_path_buffer,
    );
    var database = try verso.storage.sqlite.Database.open(init.gpa, database_path);
    defer database.close();

    const stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false;
    var logger = logging.Logger.initWithOptions(
        init.gpa,
        app_config.effectiveLoggingFormat(stderr_is_tty),
        .{
            .use_color = stderr_is_tty,
            .omit_null_fields = app_config.logging.omit_null_fields,
        },
    );
    const migration_directory_path = try verso.storage.migration_directory.resolveMigrationDirectory(
        init.io,
        init.gpa,
        app_config.migrations.path,
    );
    defer init.gpa.free(migration_directory_path);
    var migration_context = database.migrationContext(
        init.io,
        init.gpa,
        migration_directory_path,
        &logger,
    );
    const applied_migration_count = try migration_context.migrateUp();
    var output_buffer: [128]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    if (applied_migration_count == 0) {
        try output_writer.interface.writeAll("Database is up to date.\n");
    } else {
        try output_writer.interface.print("Applied {d} migration{s}.\n", .{
            applied_migration_count,
            if (applied_migration_count == 1) "" else "s",
        });
    }
    try output_writer.flush();
}
