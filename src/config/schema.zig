const std = @import("std");
const types = @import("types.zig");

pub const Config = types.Config;

/// Sparse presentation metadata for the serve configuration surface.
///
/// The configuration path is the only reference to configuration semantics in
/// this record. Its type, default, and validation rules always come from
/// Config itself.
pub const CliMetadata = struct {
    config_field: []const u8,
    cli_enabled: bool,
    description: ?[]const u8 = null,
};

pub const serve_cli_metadata = [_]CliMetadata{
    .{ .config_field = "runtime.environment", .cli_enabled = true, .description = "Runtime environment: development or production." },
    .{ .config_field = "logging.format", .cli_enabled = true, .description = "Logging format: auto, json, text, or pretty." },
    .{ .config_field = "logging.omit_null_fields", .cli_enabled = true, .description = "Include null fields in logs: true or false." },
    .{ .config_field = "site.name", .cli_enabled = true, .description = "Publication name." },
    .{ .config_field = "site.base_url", .cli_enabled = true, .description = "Public site URL." },
    .{ .config_field = "server.host", .cli_enabled = true, .description = "HTTP bind host." },
    .{ .config_field = "server.port", .cli_enabled = true, .description = "HTTP bind port." },
    .{ .config_field = "database.url", .cli_enabled = true, .description = "SQLite database path or URL." },
    .{ .config_field = "migrations.path", .cli_enabled = true, .description = "Migration directory." },
    .{ .config_field = "migrations.run_on_startup", .cli_enabled = true, .description = "Run pending migrations at startup." },
    .{ .config_field = "storage.filesystem.path", .cli_enabled = true, .description = "Filesystem asset directory." },
    .{ .config_field = "cache.path", .cli_enabled = true, .description = "Derived HTML cache directory." },
    .{ .config_field = "public_static_root", .cli_enabled = true, .description = "Configured public static directory." },
    .{ .config_field = "ui.language", .cli_enabled = true, .description = "UI language: en." },
    .{ .config_field = "ui.theme", .cli_enabled = true, .description = "UI theme name." },
    .{ .config_field = "ui.logo", .cli_enabled = true, .description = "UI logo path." },
    .{ .config_field = "ui.icon", .cli_enabled = true, .description = "Reserved UI icon path." },
    .{ .config_field = "ui.logo_wordmark", .cli_enabled = true, .description = "Reserved UI wordmark path." },
    .{ .config_field = "features.math", .cli_enabled = true, .description = "Enable math rendering." },
    .{ .config_field = "features.interactive_sections", .cli_enabled = true, .description = "Enable interactive sections." },
    .{ .config_field = "mcp.enabled", .cli_enabled = true, .description = "Enable the MCP interface." },
    .{ .config_field = "mcp.allow_publish", .cli_enabled = true, .description = "Allow the MCP interface to publish." },
};

pub const EnvironmentField = struct {
    config_field: []const u8,
    environment_name: []const u8,
};

/// Every scalar configuration field receives an environment mapping. Tagged
/// unions are represented by explicit paths, keeping exceptional names small
/// without maintaining a second allowlist.
pub const environment_fields = makeEnvironmentFields();

pub const environment_reference = makeEnvironmentReference();

comptime {
    validateCliMetadata(serve_cli_metadata[0..]);
}

pub fn fieldType(comptime path: []const u8) type {
    @setEvalBranchQuota(10_000);
    return resolvePath(Config, path);
}

pub fn cliName(comptime path: []const u8) [path.len]u8 {
    @setEvalBranchQuota(10_000);
    var result: [path.len]u8 = undefined;
    for (path, 0..) |character, index| {
        result[index] = if (character == '.') '_' else character;
    }
    return result;
}

pub fn cliOptionName(comptime path: []const u8) [path.len]u8 {
    @setEvalBranchQuota(10_000);
    var result: [path.len]u8 = undefined;
    for (path, 0..) |character, index| {
        result[index] = if (character == '.' or character == '_') '-' else character;
    }
    return result;
}

pub fn cliPlaceholderName(comptime path: []const u8) [path.len]u8 {
    @setEvalBranchQuota(10_000);
    var result: [path.len]u8 = undefined;
    for (path, 0..) |character, index| {
        result[index] = if (character == '.') '_' else std.ascii.toUpper(character);
    }
    return result;
}

fn validateCliMetadata(comptime metadata: []const CliMetadata) void {
    for (metadata, 0..) |entry, index| {
        _ = fieldType(entry.config_field);
        if (entry.description) |description| {
            if (description.len == 0) {
                @compileError("serve CLI metadata descriptions must not be empty");
            }
        }
        for (metadata[0..index]) |previous| {
            if (std.mem.eql(u8, entry.config_field, previous.config_field)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate serve CLI metadata path '{s}'",
                    .{entry.config_field},
                ));
            }
        }
    }
}

fn resolvePath(comptime Root: type, comptime path: []const u8) type {
    if (path.len == 0) @compileError("configuration field path must not be empty");

    const separator = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
    const head = path[0..separator];
    const tail = if (separator == path.len) "" else path[separator + 1 ..];
    const member = memberType(Root, head);
    return if (tail.len == 0) member else resolvePath(member, tail);
}

fn memberType(comptime Parent: type, comptime name: []const u8) type {
    switch (@typeInfo(Parent)) {
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) return field.type;
            }
        },
        .@"union" => |union_info| {
            inline for (union_info.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) return field.type;
            }
        },
        else => {},
    }
    @compileError(std.fmt.comptimePrint(
        "unknown Config field path segment '{s}'",
        .{name},
    ));
}

fn makeEnvironmentFields() [environmentFieldCount(Config)]EnvironmentField {
    const count = environmentFieldCount(Config);
    var fields: [count]EnvironmentField = undefined;
    var index: usize = 0;
    fillEnvironmentFields(Config, "", &fields, &index);
    return fields;
}

fn environmentFieldCount(comptime Struct: type) usize {
    var count: usize = 0;
    inline for (@typeInfo(Struct).@"struct".fields) |field| {
        if (comptime Struct == Config and std.mem.eql(u8, field.name, "storage")) {
            count += 1;
            continue;
        }
        count += switch (@typeInfo(field.type)) {
            .@"struct" => environmentFieldCount(field.type),
            .@"union" => @compileError("configuration union requires an explicit environment mapping"),
            else => 1,
        };
    }
    return count;
}

fn fillEnvironmentFields(
    comptime Struct: type,
    comptime prefix: []const u8,
    fields: anytype,
    index: *usize,
) void {
    inline for (@typeInfo(Struct).@"struct".fields) |field| {
        const field_path = joinPath(prefix, field.name);
        if (comptime Struct == Config and std.mem.eql(u8, field.name, "storage")) {
            const storage_path = joinPath(field_path[0..], "filesystem.path");
            fields[index.*] = .{
                .config_field = storage_path[0..],
                .environment_name = environmentName(storage_path[0..]),
            };
            index.* += 1;
            continue;
        }

        switch (@typeInfo(field.type)) {
            .@"struct" => fillEnvironmentFields(field.type, field_path[0..], fields, index),
            .@"union" => @compileError("configuration union requires an explicit environment mapping"),
            else => {
                fields[index.*] = .{
                    .config_field = field_path[0..],
                    .environment_name = environmentName(field_path[0..]),
                };
                index.* += 1;
            },
        }
    }
}

fn joinPath(comptime prefix: []const u8, comptime name: []const u8) [prefix.len + name.len + @intFromBool(prefix.len != 0)]u8 {
    var result: [prefix.len + name.len + @intFromBool(prefix.len != 0)]u8 = undefined;
    var index: usize = 0;
    if (prefix.len != 0) {
        @memcpy(result[0..prefix.len], prefix);
        index = prefix.len;
        result[index] = '.';
        index += 1;
    }
    @memcpy(result[index..], name);
    return result;
}

pub fn environmentName(comptime path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "storage.filesystem.path")) return "VERSO_STORAGE_FS_PATH";
    return comptime std.fmt.comptimePrint("VERSO_{s}", .{cliPlaceholderName(path)});
}

fn environmentReferenceLength() usize {
    @setEvalBranchQuota(100_000);
    var length: usize = 0;
    inline for (environment_fields) |field| {
        length += std.fmt.comptimePrint("{s} = {s}\n", .{ field.environment_name, field.config_field }).len;
    }
    return length;
}

fn makeEnvironmentReference() [environmentReferenceLength()]u8 {
    @setEvalBranchQuota(100_000);
    var result: [environmentReferenceLength()]u8 = undefined;
    var index: usize = 0;
    inline for (environment_fields) |field| {
        const line = std.fmt.comptimePrint("{s} = {s}\n", .{ field.environment_name, field.config_field });
        @memcpy(result[index .. index + line.len], line);
        index += line.len;
    }
    return result;
}

test "serve metadata resolves only Config paths" {
    try std.testing.expectEqual(@as(usize, serve_cli_metadata.len), 23);
    try std.testing.expect(fieldType("server") == Config.Server);
    try std.testing.expectEqualStrings("server_port", cliName("server.port")[0..]);
    try std.testing.expectEqualStrings("server-port", cliOptionName("server.port")[0..]);
    try std.testing.expectEqualStrings("VERSO_STORAGE_FS_PATH", environmentName("storage.filesystem.path"));
}

test "environment mappings are reflected from Config" {
    try std.testing.expect(environment_fields.len > serve_cli_metadata.len);
    try std.testing.expect(std.mem.indexOf(u8, environment_reference, "VERSO_SERVER_PORT") != null);
    try std.testing.expect(std.mem.indexOf(u8, environment_reference, "VERSO_STORAGE_FS_PATH") != null);
}
