const std = @import("std");
const clap = @import("clap");
const verso = @import("verso");
const command_support = @import("support.zig");

const AuthCommand = enum {
    bootstrap_owner,
};

pub fn run(init: std.process.Init, command_args: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\    --login <LOGIN>        Local owner login identifier.
        \\    --password-hash <HASH> Argon2id owner password hash.
        \\    --subject <SUBJECT>    Optional initial owner identity subject.
        \\    --display-name <NAME>  Initial owner display name.
        \\    --email <EMAIL>        Optional owner email address.
        \\<command>                Auth command: bootstrap-owner.
        \\
    );
    const parsers = .{
        .command = parseAuthCommand,
        .LOGIN = clap.parsers.string,
        .HASH = clap.parsers.string,
        .SUBJECT = clap.parsers.string,
        .NAME = clap.parsers.string,
        .EMAIL = clap.parsers.string,
    };

    var diagnostics = clap.Diagnostic{};
    var parsed_args = clap.parseEx(clap.Help, &params, parsers, command_args, .{
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
    return switch (parsed_args.positionals[0] orelse return error.InvalidArguments) {
        .bootstrap_owner => bootstrapOwner(init, parsed_args.args),
    };
}

fn parseAuthCommand(command_name: []const u8) error{InvalidCommand}!AuthCommand {
    if (std.mem.eql(u8, command_name, "bootstrap-owner")) return .bootstrap_owner;
    return error.InvalidCommand;
}

fn bootstrapOwner(init: std.process.Init, args: anytype) !void {
    const login = @field(args, "login") orelse return error.InvalidArguments;
    const display_name = @field(args, "display-name") orelse return error.InvalidArguments;
    const subject = @field(args, "subject");
    const password_hash = @field(args, "password-hash") orelse init.environ_map.get("VERSO_BOOTSTRAP_PASSWORD_HASH");
    const password_text = if (password_hash == null)
        init.environ_map.get("VERSO_BOOTSTRAP_PASSWORD") orelse return error.MissingBootstrapPassword
    else
        null;

    var parsed_config = verso.config.loadFile(
        init.io,
        init.gpa,
        "verso.toml",
        .{ .envs = init.environ_map },
    ) catch |configuration_error| {
        command_support.logConfigurationFailure(init, "auth bootstrap-owner", configuration_error);
        return configuration_error;
    };
    defer parsed_config.deinit();
    const app_config = parsed_config.value;

    try verso.application.bootstrap.prepareConfiguredDirectories(init.io, std.Io.Dir.cwd(), app_config);
    var database_path_buffer: [1024]u8 = undefined;
    const database_path = try verso.application.bootstrap.resolveDatabasePath(app_config, &database_path_buffer);
    var database = try verso.storage.sqlite.Database.open(init.gpa, database_path);
    defer database.close();

    const stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false;
    var logger = verso.logging.Logger.initWithOptions(
        init.gpa,
        app_config.effectiveLoggingFormat(stderr_is_tty),
        .{ .use_color = stderr_is_tty, .omit_null_fields = app_config.logging.omit_null_fields },
    );
    const migration_path = try verso.storage.migration_directory.resolveMigrationDirectory(
        init.io,
        init.gpa,
        app_config.migrations.path,
    );
    defer init.gpa.free(migration_path);
    var migration_context = database.migrationContext(init.io, init.gpa, migration_path, &logger);
    _ = try migration_context.migrateUp();

    var identity_store = verso.storage.identity.Store.init(database.sqliteHandle());
    var identity_service = verso.application.identity.Service.initForInterface(
        init.io,
        init.gpa,
        &identity_store,
        .cli,
    );
    const owner_id = if (password_hash) |hash| try identity_service.bootstrapLocalOwnerHash(.{
        .subject = subject,
        .display_name = display_name,
        .email = @field(args, "email"),
    }, login, hash) else try identity_service.bootstrapLocalOwnerPassword(.{
        .subject = subject,
        .display_name = display_name,
        .email = @field(args, "email"),
    }, login, password_text.?);

    var output_buffer: [128]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output_writer.interface.print("owner_id={d} login={s}\n", .{ owner_id, login });
    try output_writer.flush();
}
