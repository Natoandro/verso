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
        command_support.logCommandFailure(init, "auth", "argument_parse", "warn", parse_error);
        diagnostics.reportToFile(init.io, .stderr(), parse_error) catch |failure| {
            command_support.logCommandFailure(init, "auth", "argument_diagnostic", "error", failure);
            return failure;
        };
        return parse_error;
    };
    defer parsed_args.deinit();

    if (parsed_args.args.help != 0) {
        return clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{}) catch |failure| {
            command_support.logCommandFailure(init, "auth", "help_output", "error", failure);
            return failure;
        };
    }
    const command_name = parsed_args.positionals[0] orelse {
        command_support.logCommandFailure(init, "auth", "command_selection", "warn", error.InvalidArguments);
        return error.InvalidArguments;
    };
    return switch (command_name) {
        .bootstrap_owner => bootstrapOwner(init, parsed_args.args),
    };
}

fn parseAuthCommand(command_name: []const u8) error{InvalidCommand}!AuthCommand {
    if (std.mem.eql(u8, command_name, "bootstrap-owner")) return .bootstrap_owner;
    return error.InvalidCommand;
}

fn bootstrapOwner(init: std.process.Init, args: anytype) !void {
    const login = @field(args, "login") orelse {
        command_support.logCommandFailure(init, "auth bootstrap-owner", "argument_validation", "warn", error.InvalidArguments);
        return error.InvalidArguments;
    };
    const display_name = @field(args, "display-name") orelse {
        command_support.logCommandFailure(init, "auth bootstrap-owner", "argument_validation", "warn", error.InvalidArguments);
        return error.InvalidArguments;
    };
    const subject = @field(args, "subject");
    const password_hash = @field(args, "password-hash") orelse init.environ_map.get("VERSO_BOOTSTRAP_PASSWORD_HASH");
    const password_text = if (password_hash == null)
        init.environ_map.get("VERSO_BOOTSTRAP_PASSWORD") orelse {
            command_support.logCommandFailure(init, "auth bootstrap-owner", "argument_validation", "warn", error.MissingBootstrapPassword);
            return error.MissingBootstrapPassword;
        }
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

    verso.application.bootstrap.prepareConfiguredDirectories(init.io, std.Io.Dir.cwd(), app_config) catch |failure| {
        command_support.logCommandFailure(init, "auth bootstrap-owner", "directories", "error", failure);
        return failure;
    };
    var database_path_buffer: [1024]u8 = undefined;
    const database_path = verso.application.bootstrap.resolveDatabasePath(app_config, &database_path_buffer) catch |failure| {
        command_support.logCommandFailure(init, "auth bootstrap-owner", "database_path", "error", failure);
        return failure;
    };
    var database = verso.storage.sqlite.Database.open(init.gpa, database_path) catch |failure| {
        command_support.logCommandFailure(init, "auth bootstrap-owner", "database_open", "error", failure);
        return failure;
    };
    defer database.close();

    const stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false;
    var logger = verso.logging.Logger.initWithOptions(
        init.gpa,
        app_config.effectiveLoggingFormat(stderr_is_tty),
        .{ .use_color = stderr_is_tty, .omit_null_fields = app_config.logging.omit_null_fields },
    );
    const migration_path = verso.storage.migration_directory.resolveMigrationDirectory(
        init.io,
        init.gpa,
        app_config.migrations.path,
    ) catch |failure| {
        command_support.logCommandFailure(init, "auth bootstrap-owner", "migration_directory", "error", failure);
        return failure;
    };
    defer init.gpa.free(migration_path);
    var migration_context = database.migrationContext(init.io, init.gpa, migration_path, &logger);
    _ = migration_context.migrateUp() catch |failure| {
        command_support.logCommandFailure(init, "auth bootstrap-owner", "migrations", "error", failure);
        return failure;
    };

    var identity_store = verso.storage.identity.Store.init(database.sqliteHandle());
    var identity_service = verso.application.identity.Service.initForInterface(
        init.io,
        init.gpa,
        &identity_store,
        .cli,
    );
    const owner_id = if (password_hash) |hash| identity_service.bootstrapLocalOwnerHash(.{
        .subject = subject,
        .display_name = display_name,
        .email = @field(args, "email"),
    }, login, hash) catch |failure| {
        command_support.logCommandFailure(init, "auth bootstrap-owner", "owner_provision", "error", failure);
        return failure;
    } else identity_service.bootstrapLocalOwnerPassword(.{
        .subject = subject,
        .display_name = display_name,
        .email = @field(args, "email"),
    }, login, password_text.?) catch |failure| {
        command_support.logCommandFailure(init, "auth bootstrap-owner", "owner_provision", "error", failure);
        return failure;
    };

    var output_buffer: [128]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    output_writer.interface.print("owner_id={d} login={s}\n", .{ owner_id, login }) catch |failure| {
        command_support.logCommandFailure(init, "auth bootstrap-owner", "stdout", "error", failure);
        return failure;
    };
    output_writer.flush() catch |failure| {
        command_support.logCommandFailure(init, "auth bootstrap-owner", "stdout", "error", failure);
        return failure;
    };
}
