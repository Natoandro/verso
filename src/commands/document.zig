const std = @import("std");
const clap = @import("clap");
const verso = @import("verso");
const command_support = @import("support.zig");

const DocumentCommand = enum {
    create_draft,
};

pub fn run(init: std.process.Init, command_args: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\    --id <ID>              Existing stable ID to continue creating version 1.
        \\    --type <TYPE>          Logical document type (article).
        \\    --title <TITLE>        Draft title.
        \\    --slug <SLUG>          Draft slug.
        \\    --description <TEXT>   Optional draft description.
        \\    --language <LANG>      Draft language (default: en).
        \\    --text <MARKDOWN>      Initial Markdown text.
        \\<command>                Document command: create-draft.
        \\
    );
    const parsers = .{
        .command = parseDocumentCommand,
        .ID = clap.parsers.int(i64, 10),
        .TYPE = clap.parsers.string,
        .TITLE = clap.parsers.string,
        .SLUG = clap.parsers.string,
        .TEXT = clap.parsers.string,
        .MARKDOWN = clap.parsers.string,
        .LANG = clap.parsers.string,
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

    const command = parsed_args.positionals[0] orelse return error.InvalidArguments;
    switch (command) {
        .create_draft => try createDraft(init, parsed_args.args),
    }
}

fn parseDocumentCommand(command_name: []const u8) error{InvalidCommand}!DocumentCommand {
    if (std.mem.eql(u8, command_name, "create-draft")) return .create_draft;
    return error.InvalidCommand;
}

fn createDraft(init: std.process.Init, args: anytype) !void {
    const raw_type = args.type orelse return error.InvalidArguments;
    const title = args.title orelse return error.InvalidArguments;
    const slug = args.slug orelse return error.InvalidArguments;
    const markdown = args.text orelse return error.InvalidArguments;
    const document_type = try verso.domain.document.DocumentType.parse(raw_type);

    var parsed_config = verso.config.loadFile(
        init.io,
        init.gpa,
        "verso.toml",
        .{ .envs = init.environ_map },
    ) catch |configuration_error| {
        command_support.logConfigurationFailure(init, "document create-draft", configuration_error);
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
