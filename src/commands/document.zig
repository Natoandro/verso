const std = @import("std");
const clap = @import("clap");
const verso = @import("verso");
const command_options = @import("options.zig");
const command_support = @import("support.zig");

const DocumentCommand = enum {
    create_draft,
    create_next_version,
    section,
};

const SectionOperation = enum {
    insert,
    update,
    move,
    duplicate,
    delete,
};

const document_help =
    "    --id <ID>              Existing stable ID to continue creating version 1.\n" ++
    "    --type <TYPE>          Logical document type (article).\n" ++
    "    --title <TITLE>        Draft title.\n" ++
    "    --slug <SLUG>          Draft slug.\n" ++
    "    --description <TEXT>   Optional draft description.\n" ++
    "    --language <LANG>      Draft language (default: en).\n" ++
    "    --text <MARKDOWN>      Initial Markdown text.\n" ++
    "    --version-id <ID>      Version ID for next-version or section operation.\n" ++
    "    --section-id <ID>      Existing section ID for a section operation.\n" ++
    "    --position <POSITION>  Zero-based section position.\n" ++
    "    --revision <REVISION> Expected draft revision.\n" ++
    "    --asset <ASSET>        Image asset name.\n" ++
    "    --alt <TEXT>           Image alternative text.\n" ++
    "    --caption <TEXT>       Optional image caption.\n" ++
    "    --display <DISPLAY>    Image display: inline, wide, or full.\n" ++
    "<command>                 Document command: create-draft, create-next-version, or section.\n" ++
    "<operation>               Section operation: insert, update, move, duplicate, or delete.\n";

pub fn run(
    init: std.process.Init,
    command_args: *std.process.Args.Iterator,
    inherited_overrides: verso.config.CliOverrides,
) !void {
    const params = comptime clap.parseParamsComptime(command_options.document_help ++ "\n" ++ document_help);
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

    const command = try parseDocumentCommand(parsed_args.positionals[0] orelse return error.InvalidArguments);
    const cli_overrides = command_options.merge(
        inherited_overrides,
        command_options.overrides(parsed_args.args),
    );
    switch (command) {
        .create_draft => try createDraft(init, parsed_args.args, cli_overrides),
        .create_next_version => try createNextVersion(init, parsed_args.args, cli_overrides),
        .section => try section(
            init,
            try parseSectionOperation(parsed_args.positionals[1] orelse return error.InvalidArguments),
            parsed_args.args,
            cli_overrides,
        ),
    }
}

fn parseDocumentCommand(command_name: []const u8) error{InvalidCommand}!DocumentCommand {
    if (std.mem.eql(u8, command_name, "create-draft")) return .create_draft;
    if (std.mem.eql(u8, command_name, "create-next-version")) return .create_next_version;
    if (std.mem.eql(u8, command_name, "section")) return .section;
    return error.InvalidCommand;
}

fn parseSectionOperation(operation_name: []const u8) error{InvalidOperation}!SectionOperation {
    if (std.mem.eql(u8, operation_name, "insert")) return .insert;
    if (std.mem.eql(u8, operation_name, "update")) return .update;
    if (std.mem.eql(u8, operation_name, "move")) return .move;
    if (std.mem.eql(u8, operation_name, "duplicate")) return .duplicate;
    if (std.mem.eql(u8, operation_name, "delete")) return .delete;
    return error.InvalidOperation;
}

fn createDraft(
    init: std.process.Init,
    args: anytype,
    cli_overrides: verso.config.CliOverrides,
) !void {
    const raw_type = args.type orelse return error.InvalidArguments;
    const title = args.title orelse return error.InvalidArguments;
    const slug = args.slug orelse return error.InvalidArguments;
    const markdown = args.text orelse return error.InvalidArguments;
    const document_type = try verso.domain.document.DocumentType.parse(raw_type);

    var parsed_config = verso.config.loadFile(
        init.io,
        init.gpa,
        "verso.toml",
        .{ .envs = init.environ_map, .cli = cli_overrides },
    ) catch |configuration_error| {
        command_support.logConfigurationFailure(init, "document create-draft", configuration_error);
        return configuration_error;
    };
    defer parsed_config.deinit();
    const app_config = parsed_config.value;
    command_support.logConfigurationLoaded(init, "document create-draft", app_config, cli_overrides);

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
    if (app_config.migrations.run_on_startup) {
        const migration_path = try verso.storage.migration_directory.resolveMigrationDirectory(
            init.io,
            init.gpa,
            app_config.migrations.path,
        );
        defer init.gpa.free(migration_path);
        var migration_context = database.migrationContext(
            init.io,
            init.gpa,
            migration_path,
            &logger,
        );
        _ = try migration_context.migrateUp();
    }

    var document_store = verso.storage.documents.Store.init(database.sqliteHandle());
    var document_service = verso.application.documents.Service.init(init.gpa, &document_store);
    const draft = try document_service.createDraft(.local_operator, .{
        .document_id = args.id,
        .document_type = document_type,
        .title = title,
        .slug = slug,
        .description = args.description,
        .language = args.language orelse "en",
        .markdown = markdown,
    });

    var output_buffer: [256]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output_writer.interface.print(
        "document_id={d} version_id={d} version={d} section_id={d} state={s}\n",
        .{ draft.document_id, draft.version_id, draft.version_number, draft.section_id, draft.state.text() },
    );
    try output_writer.flush();
}

fn createNextVersion(
    init: std.process.Init,
    args: anytype,
    cli_overrides: verso.config.CliOverrides,
) !void {
    const source_version_id = @field(args, "version-id") orelse return error.InvalidArguments;

    var parsed_config = verso.config.loadFile(
        init.io,
        init.gpa,
        "verso.toml",
        .{ .envs = init.environ_map, .cli = cli_overrides },
    ) catch |configuration_error| {
        command_support.logConfigurationFailure(init, "document create-next-version", configuration_error);
        return configuration_error;
    };
    defer parsed_config.deinit();
    const app_config = parsed_config.value;
    command_support.logConfigurationLoaded(init, "document create-next-version", app_config, cli_overrides);

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
    if (app_config.migrations.run_on_startup) {
        const migration_path = try verso.storage.migration_directory.resolveMigrationDirectory(
            init.io,
            init.gpa,
            app_config.migrations.path,
        );
        defer init.gpa.free(migration_path);
        var migration_context = database.migrationContext(
            init.io,
            init.gpa,
            migration_path,
            &logger,
        );
        _ = try migration_context.migrateUp();
    }

    var document_store = verso.storage.documents.Store.init(database.sqliteHandle());
    var document_service = verso.application.documents.Service.init(init.gpa, &document_store);
    const next_version = try document_service.createNextVersion(.local_operator, .{
        .source_version_id = source_version_id,
    });

    var output_buffer: [256]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output_writer.interface.print(
        "document_id={d} version_id={d} version={d} based_on_version_id={d} state={s}\n",
        .{
            next_version.document_id,
            next_version.version_id,
            next_version.version_number,
            next_version.based_on_version_id,
            next_version.state.text(),
        },
    );
    try output_writer.flush();
}

fn section(
    init: std.process.Init,
    operation: SectionOperation,
    args: anytype,
    cli_overrides: verso.config.CliOverrides,
) !void {
    const version_id = @field(args, "version-id") orelse return error.InvalidArguments;
    const expected_revision = args.revision orelse return error.InvalidArguments;

    var parsed_config = verso.config.loadFile(
        init.io,
        init.gpa,
        "verso.toml",
        .{ .envs = init.environ_map, .cli = cli_overrides },
    ) catch |configuration_error| {
        command_support.logConfigurationFailure(init, "document section", configuration_error);
        return configuration_error;
    };
    defer parsed_config.deinit();
    const app_config = parsed_config.value;
    command_support.logConfigurationLoaded(init, "document section", app_config, cli_overrides);

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
    if (app_config.migrations.run_on_startup) {
        const migration_path = try verso.storage.migration_directory.resolveMigrationDirectory(
            init.io,
            init.gpa,
            app_config.migrations.path,
        );
        defer init.gpa.free(migration_path);
        var migration_context = database.migrationContext(
            init.io,
            init.gpa,
            migration_path,
            &logger,
        );
        _ = try migration_context.migrateUp();
    }

    var document_store = verso.storage.documents.Store.init(database.sqliteHandle());
    var document_service = verso.application.documents.Service.init(init.gpa, &document_store);
    const result = switch (operation) {
        .insert => try document_service.insertSection(.local_operator, .{
            .version_id = version_id,
            .position = args.position orelse return error.InvalidArguments,
            .expected_revision = expected_revision,
            .payload = try parsePayload(args),
        }),
        .update => try document_service.updateSection(.local_operator, .{
            .version_id = version_id,
            .section_id = @field(args, "section-id") orelse return error.InvalidArguments,
            .expected_revision = expected_revision,
            .payload = try parsePayload(args),
        }),
        .move => try document_service.moveSection(.local_operator, .{
            .version_id = version_id,
            .section_id = @field(args, "section-id") orelse return error.InvalidArguments,
            .position = args.position orelse return error.InvalidArguments,
            .expected_revision = expected_revision,
        }),
        .duplicate => try document_service.duplicateSection(.local_operator, .{
            .version_id = version_id,
            .section_id = @field(args, "section-id") orelse return error.InvalidArguments,
            .position = args.position orelse return error.InvalidArguments,
            .expected_revision = expected_revision,
        }),
        .delete => try document_service.deleteSection(.local_operator, .{
            .version_id = version_id,
            .section_id = @field(args, "section-id") orelse return error.InvalidArguments,
            .expected_revision = expected_revision,
        }),
    };

    var output_buffer: [256]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output_writer.interface.print(
        "section_id={d} revision={d}\n",
        .{ result.section_id, result.revision_number },
    );
    try output_writer.flush();
}

fn parsePayload(args: anytype) !verso.domain.sections.Payload {
    const raw_type = args.type orelse return error.InvalidArguments;
    const kind = try verso.domain.sections.SectionKind.parse(raw_type);
    return switch (kind) {
        .text => .{ .text = .{ .markdown = args.text orelse return error.InvalidArguments } },
        .image => .{ .image = .{
            .asset = args.asset orelse return error.InvalidArguments,
            .alt = args.alt orelse return error.InvalidArguments,
            .caption = args.caption,
            .display = if (args.display) |display| try verso.domain.sections.ImageDisplay.parse(display) else null,
        } },
    };
}
