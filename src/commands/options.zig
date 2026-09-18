const std = @import("std");
const clap = @import("clap");
const verso = @import("verso");

pub const global_help =
    "-h, --help                                      Display this help and exit.\n" ++
    "    --config <PATH>                              Alternate configuration file.\n";

fn serveHelpLine(comptime metadata: verso.config.CliMetadata) []const u8 {
    @setEvalBranchQuota(100_000);
    const option_name = verso.config.cliOptionName(metadata.config_field);
    const placeholder = verso.config.cliPlaceholderName(metadata.config_field);
    return std.fmt.comptimePrint(
        "    --{s} <{s}> {s}\n",
        .{ option_name, placeholder, metadata.description orelse "" },
    );
}

fn serveHelpLength() usize {
    @setEvalBranchQuota(100_000);
    var length: usize = global_help.len;
    inline for (verso.config.serve_cli_metadata) |metadata| {
        if (metadata.cli_enabled) length += serveHelpLine(metadata).len;
    }
    return length;
}

fn makeServeHelp() [serveHelpLength()]u8 {
    @setEvalBranchQuota(100_000);
    var result: [serveHelpLength()]u8 = undefined;
    var index: usize = 0;
    @memcpy(result[index .. index + global_help.len], global_help);
    index += global_help.len;
    inline for (verso.config.serve_cli_metadata) |metadata| {
        if (metadata.cli_enabled) {
            const line = serveHelpLine(metadata);
            @memcpy(result[index .. index + line.len], line);
            index += line.len;
        }
    }
    return result;
}

pub const serve_help_text = makeServeHelp();
pub const server_help = serve_help_text[0..];

const migration_config_fields = .{
    .{ "logging.format", "Logging format: auto, json, text, or pretty." },
    .{ "logging.omit_null_fields", "Include null fields in logs: true or false." },
    .{ "database.url", "SQLite database path or URL." },
    .{ "migrations.path", "Migration directory." },
};

fn migrationHelpLine(comptime path: []const u8, comptime description: []const u8) []const u8 {
    @setEvalBranchQuota(100_000);
    const option_name = verso.config.cliOptionName(path);
    const placeholder = verso.config.cliPlaceholderName(path);
    return std.fmt.comptimePrint(
        "    --{s} <{s}> {s}\n",
        .{ option_name, placeholder, description },
    );
}

fn migrationHelpLength() usize {
    var length: usize = global_help.len;
    inline for (migration_config_fields) |field| {
        length += migrationHelpLine(field[0], field[1]).len;
    }
    return length;
}

fn makeMigrationHelp() [migrationHelpLength()]u8 {
    @setEvalBranchQuota(100_000);
    var result: [migrationHelpLength()]u8 = undefined;
    var index: usize = 0;
    @memcpy(result[index .. index + global_help.len], global_help);
    index += global_help.len;
    inline for (migration_config_fields) |field| {
        const line = migrationHelpLine(field[0], field[1]);
        @memcpy(result[index .. index + line.len], line);
        index += line.len;
    }
    return result;
}

pub const migration_help_text = makeMigrationHelp();
pub const migration_help = migration_help_text[0..];

pub const document_help = migration_help ++
    migrationHelpLine("runtime.environment", "Runtime environment: development or production.") ++
    migrationHelpLine("site.base_url", "Public site URL for validation.") ++
    migrationHelpLine("migrations.run_on_startup", "Run pending migrations at startup.");

// These are temporary document-command fields. Config fields below are
// reflected from Config and are not duplicated in this parser table.
const DocumentParserCount = 18;

fn serveParserCount() usize {
    var count: usize = 0;
    inline for (verso.config.serve_cli_metadata) |metadata| {
        if (metadata.cli_enabled) count += 1;
    }
    return count;
}

fn configParserType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |optional| configParserType(optional.child),
        .pointer => if (T == []const u8) @TypeOf(clap.parsers.string) else @compileError("unsupported CLI pointer type"),
        .bool => @TypeOf(parseBool),
        .int => @TypeOf(clap.parsers.int(T, 10)),
        .@"enum" => @TypeOf(clap.parsers.enumeration(T)),
        else => @compileError("unsupported Config CLI parser type"),
    };
}

fn configParser(comptime T: type) configParserType(T) {
    return switch (@typeInfo(T)) {
        .optional => |optional| configParser(optional.child),
        .pointer => clap.parsers.string,
        .bool => parseBool,
        .int => clap.parsers.int(T, 10),
        .@"enum" => clap.parsers.enumeration(T),
        else => @compileError("unsupported Config CLI parser type"),
    };
}

fn parserSetType() type {
    var names: [DocumentParserCount + serveParserCount()][]const u8 = undefined;
    var field_types: [names.len]type = undefined;
    var attrs: [names.len]std.builtin.Type.StructField.Attributes = @splat(.{});
    var index: usize = 0;

    inline for (.{
        .{ "command", @TypeOf(clap.parsers.string) },
        .{ "operation", @TypeOf(clap.parsers.string) },
        .{ "PATH", @TypeOf(clap.parsers.string) },
        .{ "ID", @TypeOf(clap.parsers.int(i64, 10)) },
        .{ "VERSION_ID", @TypeOf(clap.parsers.int(i64, 10)) },
        .{ "SECTION_ID", @TypeOf(clap.parsers.int(i64, 10)) },
        .{ "POSITION", @TypeOf(clap.parsers.int(u32, 10)) },
        .{ "REVISION", @TypeOf(clap.parsers.int(u64, 10)) },
        .{ "TYPE", @TypeOf(clap.parsers.string) },
        .{ "TITLE", @TypeOf(clap.parsers.string) },
        .{ "SLUG", @TypeOf(clap.parsers.string) },
        .{ "TEXT", @TypeOf(clap.parsers.string) },
        .{ "MARKDOWN", @TypeOf(clap.parsers.string) },
        .{ "LANG", @TypeOf(clap.parsers.string) },
        .{ "ASSET", @TypeOf(clap.parsers.string) },
        .{ "ALT", @TypeOf(clap.parsers.string) },
        .{ "CAPTION", @TypeOf(clap.parsers.string) },
        .{ "DISPLAY", @TypeOf(clap.parsers.string) },
    }) |entry| {
        names[index] = entry[0];
        field_types[index] = entry[1];
        index += 1;
    }
    inline for (verso.config.serve_cli_metadata) |metadata| {
        if (metadata.cli_enabled) {
            const placeholder = verso.config.cliPlaceholderName(metadata.config_field);
            names[index] = placeholder[0..];
            field_types[index] = configParserType(verso.config.fieldType(metadata.config_field));
            index += 1;
        }
    }
    return @Struct(.auto, null, &names, &field_types, &attrs);
}

const ParserSet = parserSetType();

fn makeParsers() ParserSet {
    var result: ParserSet = undefined;
    result.command = clap.parsers.string;
    result.operation = clap.parsers.string;
    result.PATH = clap.parsers.string;
    result.ID = clap.parsers.int(i64, 10);
    result.VERSION_ID = clap.parsers.int(i64, 10);
    result.SECTION_ID = clap.parsers.int(i64, 10);
    result.POSITION = clap.parsers.int(u32, 10);
    result.REVISION = clap.parsers.int(u64, 10);
    result.TYPE = clap.parsers.string;
    result.TITLE = clap.parsers.string;
    result.SLUG = clap.parsers.string;
    result.TEXT = clap.parsers.string;
    result.MARKDOWN = clap.parsers.string;
    result.LANG = clap.parsers.string;
    result.ASSET = clap.parsers.string;
    result.ALT = clap.parsers.string;
    result.CAPTION = clap.parsers.string;
    result.DISPLAY = clap.parsers.string;
    inline for (verso.config.serve_cli_metadata) |metadata| {
        if (metadata.cli_enabled) {
            const placeholder = verso.config.cliPlaceholderName(metadata.config_field);
            @field(result, placeholder[0..]) = configParser(verso.config.fieldType(metadata.config_field));
        }
    }
    return result;
}

pub const parsers = makeParsers();

pub fn parseBool(value: []const u8) error{InvalidBoolean}!bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBoolean;
}

test "CLI boolean values are strict" {
    try std.testing.expectEqual(true, try parseBool("true"));
    try std.testing.expectEqual(false, try parseBool("false"));
    try std.testing.expectError(error.InvalidBoolean, parseBool("TRUE"));
    try std.testing.expectError(error.InvalidBoolean, parseBool("1"));
}

test "serve help and parsers follow Config metadata" {
    inline for (verso.config.serve_cli_metadata) |metadata| {
        if (metadata.cli_enabled) {
            const option_name = verso.config.cliOptionName(metadata.config_field);
            const placeholder = verso.config.cliPlaceholderName(metadata.config_field);
            const option = std.fmt.comptimePrint("--{s}", .{option_name});
            try std.testing.expect(std.mem.indexOf(u8, server_help, option) != null);
            try std.testing.expect(@hasField(ParserSet, placeholder[0..]));
        }
    }
}

test "migration help exposes only migration inputs" {
    try std.testing.expect(std.mem.indexOf(u8, migration_help, "--database-url") != null);
    try std.testing.expect(std.mem.indexOf(u8, migration_help, "--migrations-path") != null);
    try std.testing.expect(std.mem.indexOf(u8, migration_help, "--logging-format") != null);
    try std.testing.expect(std.mem.indexOf(u8, migration_help, "--logging-omit-null-fields") != null);
    try std.testing.expect(std.mem.indexOf(u8, migration_help, "--runtime-environment") == null);
    try std.testing.expect(std.mem.indexOf(u8, migration_help, "--site-base-url") == null);
    try std.testing.expect(std.mem.indexOf(u8, migration_help, "--migrations-run-on-startup") == null);
    try std.testing.expect(std.mem.indexOf(u8, document_help, "--migrations-run-on-startup") != null);
}

test "unset CLI options do not override configuration values" {
    const Args = struct {
        config: ?[]const u8 = null,
        @"migrations-run-on-startup": ?bool = null,
    };
    const unset = overrides(Args{});
    try std.testing.expectEqual(@as(?bool, null), unset.migrations_run_on_startup);

    const set = overrides(Args{ .@"migrations-run-on-startup" = true });
    try std.testing.expectEqual(@as(?bool, true), set.migrations_run_on_startup);
}

pub fn overrides(args: anytype) verso.config.CliOverrides {
    var result: verso.config.CliOverrides = .{};
    inline for (@typeInfo(verso.config.CliOverrides).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "config_path")) {
            if (@hasField(@TypeOf(args), "config")) {
                if (@field(args, "config")) |value| {
                    @field(result, field.name) = value;
                }
            }
        } else {
            const argument_name = comptime kebabName(field.name);
            if (@hasField(@TypeOf(args), argument_name[0..])) {
                if (@field(args, argument_name[0..])) |value| {
                    @field(result, field.name) = value;
                }
            }
        }
    }
    return result;
}

fn kebabName(comptime name: []const u8) [name.len]u8 {
    var result: [name.len]u8 = undefined;
    for (name, 0..) |character, index| {
        result[index] = if (character == '_') '-' else character;
    }
    return result;
}

pub fn merge(
    inherited: verso.config.CliOverrides,
    local: verso.config.CliOverrides,
) verso.config.CliOverrides {
    var result = inherited;
    inline for (@typeInfo(verso.config.CliOverrides).@"struct".fields) |field| {
        if (@field(local, field.name) != null) {
            @field(result, field.name) = @field(local, field.name);
        }
    }
    return result;
}
