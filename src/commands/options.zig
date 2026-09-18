const std = @import("std");
const clap = @import("clap");
const verso = @import("verso");

pub const global_help =
    "-h, --help                                      Display this help and exit.\n" ++
    "    --config <PATH>                              Alternate configuration file.\n";

pub const server_help = global_help ++
    "    --runtime-environment <ENVIRONMENT>          Runtime environment: development or production.\n" ++
    "    --logging-format <FORMAT>                    Logging format: auto, json, text, or pretty.\n" ++
    "    --logging-omit-null-fields <BOOL>            Include null fields in logs: true or false.\n" ++
    "    --site-name <NAME>                           Publication name.\n" ++
    "    --site-base-url <URL>                        Public site URL.\n" ++
    "    --server-host <HOST>                         HTTP bind host.\n" ++
    "    --server-port <PORT>                         HTTP bind port.\n" ++
    "    --database-url <URL>                         SQLite database path or URL.\n" ++
    "    --migrations-path <PATH>                     Migration directory.\n" ++
    "    --migrations-run-on-startup <BOOL>           Run pending migrations at startup.\n" ++
    "    --storage-filesystem-path <PATH>             Filesystem asset directory.\n" ++
    "    --cache-path <PATH>                          Derived HTML cache directory.\n" ++
    "    --public-static-root <PATH>                  Configured public static directory.\n" ++
    "    --ui-language <LANGUAGE>                     UI language: en.\n" ++
    "    --ui-theme <THEME>                           UI theme name.\n" ++
    "    --ui-logo <PATH>                             UI logo path.\n" ++
    "    --ui-icon <PATH>                             Reserved UI icon path.\n" ++
    "    --ui-logo-wordmark <PATH>                    Reserved UI wordmark path.\n" ++
    "    --features-math <BOOL>                       Enable math rendering.\n" ++
    "    --features-interactive-sections <BOOL>       Enable interactive sections.\n" ++
    "    --editor-local-preview-debounce-ms <MS>      Browser preview debounce interval.\n" ++
    "    --mcp-enabled <BOOL>                         Enable the MCP interface.\n" ++
    "    --mcp-allow-publish <BOOL>                   Allow the MCP interface to publish.\n";

pub const migration_help = global_help ++
    "    --runtime-environment <ENVIRONMENT>          Runtime environment: development or production.\n" ++
    "    --logging-format <FORMAT>                    Logging format: auto, json, text, or pretty.\n" ++
    "    --logging-omit-null-fields <BOOL>            Include null fields in logs: true or false.\n" ++
    "    --site-base-url <URL>                        Public site URL for validation.\n" ++
    "    --database-url <URL>                         SQLite database path or URL.\n" ++
    "    --migrations-path <PATH>                     Migration directory.\n" ++
    "    --migrations-run-on-startup <BOOL>           Run pending migrations at startup.\n";

pub const document_help = migration_help;

pub const parsers = .{
    .command = clap.parsers.string,
    .operation = clap.parsers.string,
    .PATH = clap.parsers.string,
    .ENVIRONMENT = clap.parsers.enumeration(verso.config.Environment),
    .FORMAT = clap.parsers.enumeration(verso.config.LoggingFormat),
    .BOOL = parseBool,
    .NAME = clap.parsers.string,
    .URL = clap.parsers.string,
    .HOST = clap.parsers.string,
    .PORT = clap.parsers.int(u16, 10),
    .DATABASE_URL = clap.parsers.string,
    .MIGRATIONS_PATH = clap.parsers.string,
    .STORAGE_FILESYSTEM_PATH = clap.parsers.string,
    .CACHE_PATH = clap.parsers.string,
    .PUBLIC_STATIC_ROOT = clap.parsers.string,
    .LANGUAGE = clap.parsers.enumeration(verso.config.UiLanguage),
    .THEME = clap.parsers.string,
    .LOGO = clap.parsers.string,
    .ICON = clap.parsers.string,
    .WORDMARK = clap.parsers.string,
    .MS = clap.parsers.int(u32, 10),
    .ID = clap.parsers.int(i64, 10),
    .VERSION_ID = clap.parsers.int(i64, 10),
    .SECTION_ID = clap.parsers.int(i64, 10),
    .POSITION = clap.parsers.int(u32, 10),
    .REVISION = clap.parsers.int(u64, 10),
    .TYPE = clap.parsers.string,
    .TITLE = clap.parsers.string,
    .SLUG = clap.parsers.string,
    .TEXT = clap.parsers.string,
    .MARKDOWN = clap.parsers.string,
    .LANG = clap.parsers.string,
    .ASSET = clap.parsers.string,
    .ALT = clap.parsers.string,
    .CAPTION = clap.parsers.string,
    .DISPLAY = clap.parsers.string,
};

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

pub fn overrides(args: anytype) verso.config.CliOverrides {
    var result: verso.config.CliOverrides = .{};
    inline for (@typeInfo(verso.config.CliOverrides).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "config_path")) {
            if (@hasField(@TypeOf(args), "config")) {
                @field(result, field.name) = @field(args, "config");
            }
        } else {
            const argument_name = comptime kebabName(field.name);
            if (@hasField(@TypeOf(args), argument_name[0..])) {
                @field(result, field.name) = @field(args, argument_name[0..]);
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
