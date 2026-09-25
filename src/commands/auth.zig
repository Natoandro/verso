const std = @import("std");
const clap = @import("clap");
const verso = @import("verso");
const command_options = @import("options.zig");
const command_support = @import("support.zig");

const AuthCommand = enum {
    bootstrap_owner,
    password_reset,
};

pub fn run(
    init: std.process.Init,
    command_args: *std.process.Args.Iterator,
    inherited_overrides: verso.config.CliOverrides,
) !void {
    const params = comptime clap.parseParamsComptime(command_options.global_help ++
        \\    --database-url <DATABASE_URL> SQLite database path or URL.
        \\    --site-base-url <SITE_BASE_URL> Public site URL for generated links.
        \\    --login <LOGIN>         Local owner login identifier.
        \\    --password-hash <HASH>  Argon2id owner password hash.
        \\    --subject <SUBJECT>     Optional initial owner identity subject.
        \\    --display-name <NAME>   Initial owner display name.
        \\    --email <EMAIL>         Optional owner email address.
        \\<command>                 Auth command: bootstrap-owner or password-reset.
        \\
    );
    const parsers = .{
        .command = parseAuthCommand,
        .PATH = clap.parsers.string,
        .DATABASE_URL = clap.parsers.string,
        .SITE_BASE_URL = clap.parsers.string,
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
    const cli_overrides = command_options.merge(
        inherited_overrides,
        command_options.overrides(parsed_args.args),
    );
    return switch (command_name) {
        .bootstrap_owner => bootstrapOwner(init, parsed_args.args, cli_overrides),
        .password_reset => passwordReset(init, parsed_args.args, cli_overrides),
    };
}

fn parseAuthCommand(command_name: []const u8) error{InvalidCommand}!AuthCommand {
    if (std.mem.eql(u8, command_name, "bootstrap-owner")) return .bootstrap_owner;
    if (std.mem.eql(u8, command_name, "password-reset")) return .password_reset;
    return error.InvalidCommand;
}

fn bootstrapOwner(
    init: std.process.Init,
    args: anytype,
    cli_overrides: verso.config.CliOverrides,
) !void {
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

    var parsed_config = loadAuthConfig(init, cli_overrides, "auth bootstrap-owner") catch |configuration_error| {
        return configuration_error;
    };
    defer parsed_config.deinit();
    const app_config = parsed_config.value;

    verso.application.bootstrap.prepareConfiguredDirectories(init.io, std.Io.Dir.cwd(), init.gpa, app_config) catch |failure| {
        command_support.logCommandFailure(init, "auth bootstrap-owner", "directories", "error", failure);
        return failure;
    };
    const database_path = verso.application.bootstrap.resolveDatabasePath(init.gpa, app_config) catch |failure| {
        command_support.logCommandFailure(init, "auth bootstrap-owner", "database_path", "error", failure);
        return failure;
    };
    defer init.gpa.free(database_path);
    var database = verso.storage.sqlite.Database.open(init.gpa, database_path) catch |failure| {
        command_support.logCommandFailure(init, "auth bootstrap-owner", "database_open", "error", failure);
        return failure;
    };
    defer database.close();

    var logger = tryCommandLogger(init, app_config);
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

fn passwordReset(
    init: std.process.Init,
    args: anytype,
    cli_overrides: verso.config.CliOverrides,
) !void {
    const login = @field(args, "login");
    const email = @field(args, "email");
    if ((login == null) == (email == null)) {
        command_support.logCommandFailure(init, "auth password-reset", "argument_validation", "warn", error.InvalidArguments);
        return error.InvalidArguments;
    }
    const identifier = if (login) |value|
        verso.application.identity.PasswordResetIdentifier{ .login = value }
    else
        verso.application.identity.PasswordResetIdentifier{ .email = email.? };

    var parsed_config = loadAuthConfig(init, cli_overrides, "auth password-reset") catch |configuration_error| {
        return configuration_error;
    };
    defer parsed_config.deinit();
    const app_config = parsed_config.value;
    const site_url = app_config.site.base_url orelse {
        command_support.logCommandFailure(init, "auth password-reset", "site_url", "error", error.MissingSiteBaseUrl);
        return error.MissingSiteBaseUrl;
    };
    const site_origin = verso.web.originFromBaseUrl(site_url) catch |failure| {
        command_support.logCommandFailure(init, "auth password-reset", "site_url", "error", failure);
        return failure;
    };

    verso.application.bootstrap.prepareDatabaseParentDirectory(
        init.io,
        std.Io.Dir.cwd(),
        init.gpa,
        app_config,
    ) catch |failure| {
        command_support.logCommandFailure(init, "auth password-reset", "database_directory", "error", failure);
        return failure;
    };
    const database_path = verso.application.bootstrap.resolveDatabasePath(init.gpa, app_config) catch |failure| {
        command_support.logCommandFailure(init, "auth password-reset", "database_path", "error", failure);
        return failure;
    };
    defer init.gpa.free(database_path);
    var database = verso.storage.sqlite.Database.open(init.gpa, database_path) catch |failure| {
        command_support.logCommandFailure(init, "auth password-reset", "database_open", "error", failure);
        return failure;
    };
    defer database.close();

    var logger = tryCommandLogger(init, app_config);
    const migration_path = verso.storage.migration_directory.resolveMigrationDirectory(
        init.io,
        init.gpa,
        app_config.migrations.path,
    ) catch |failure| {
        command_support.logCommandFailure(init, "auth password-reset", "migration_directory", "error", failure);
        return failure;
    };
    defer init.gpa.free(migration_path);
    var migration_context = database.migrationContext(init.io, init.gpa, migration_path, &logger);
    _ = migration_context.migrateUp() catch |failure| {
        command_support.logCommandFailure(init, "auth password-reset", "migrations", "error", failure);
        return failure;
    };

    var identity_store = verso.storage.identity.Store.init(database.sqliteHandle());
    var identity_service = verso.application.identity.Service.initForInterface(
        init.io,
        init.gpa,
        &identity_store,
        .cli,
    );
    const reset_token = identity_service.issueAdminPasswordReset(identifier) catch |failure| {
        command_support.logCommandFailure(init, "auth password-reset", "reset_issue", "error", failure);
        return failure;
    };
    const reset_link = try passwordResetLink(init.gpa, site_origin, &reset_token.value);
    defer init.gpa.free(reset_link);

    var output_buffer: [256]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    output_writer.interface.print("reset_link={s}\n", .{reset_link}) catch |failure| {
        command_support.logCommandFailure(init, "auth password-reset", "stdout", "error", failure);
        return failure;
    };
    output_writer.flush() catch |failure| {
        command_support.logCommandFailure(init, "auth password-reset", "stdout", "error", failure);
        return failure;
    };
}

fn loadAuthConfig(
    init: std.process.Init,
    cli_overrides: verso.config.CliOverrides,
    command_name: []const u8,
) !verso.config.Parsed {
    return verso.config.loadFile(
        init.io,
        init.gpa,
        "verso.toml",
        .{ .envs = init.environ_map, .cli = cli_overrides },
    ) catch |configuration_error| {
        command_support.logConfigurationFailure(init, command_name, configuration_error);
        return configuration_error;
    };
}

fn tryCommandLogger(init: std.process.Init, app_config: verso.config.Config) verso.logging.Logger {
    const stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false;
    return verso.logging.Logger.initWithOptions(
        init.gpa,
        app_config.effectiveLoggingFormat(stderr_is_tty),
        .{ .use_color = stderr_is_tty, .omit_null_fields = app_config.logging.omit_null_fields },
    );
}

fn passwordResetLink(
    allocator: std.mem.Allocator,
    site_url: []const u8,
    token: []const u8,
) ![]u8 {
    const site_origin = try verso.web.originFromBaseUrl(site_url);
    return std.fmt.allocPrint(allocator, "{s}/admin/recover/complete?token={s}", .{ site_origin, token });
}

test "password reset links use the site origin" {
    const link = try passwordResetLink(
        std.testing.allocator,
        "https://example.test/editor?source=admin#reset",
        "token",
    );
    defer std.testing.allocator.free(link);
    try std.testing.expectEqualStrings(
        "https://example.test/admin/recover/complete?token=token",
        link,
    );
}
