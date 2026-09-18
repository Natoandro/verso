const std = @import("std");
const toml = @import("toml");
const config = @import("types.zig");
const environment = @import("environment.zig");

pub const ConfigSources = struct {
    toml: []const u8 = "",
    envs: ?*const std.process.Environ.Map = null,
    cli: ?CliOverrides = null,
};

pub const CliOverrides = makeCliOverrides();

fn makeCliOverrides() type {
    const field_count = 1 + cliFieldCount(config.Config);
    var field_names: [field_count][]const u8 = undefined;
    var field_types: [field_count]type = undefined;
    var field_attrs: [field_count]std.builtin.Type.StructField.Attributes = @splat(.{});
    var field_index: usize = 0;

    appendCliField(&field_names, &field_types, &field_attrs, &field_index, "config_path", []const u8);
    fillCliFields(
        config.Config,
        "",
        &field_names,
        &field_types,
        &field_attrs,
        &field_index,
    );

    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

fn cliFieldCount(comptime Struct: type) usize {
    var count: usize = 0;
    inline for (@typeInfo(Struct).@"struct".fields) |field| {
        if (comptime Struct == config.Config and std.mem.eql(u8, field.name, "storage")) {
            count += 1;
            continue;
        }

        count += switch (@typeInfo(field.type)) {
            .@"struct" => cliFieldCount(field.type),
            .@"union" => @compileError("configuration union requires a custom CLI override"),
            else => 1,
        };
    }
    return count;
}

fn fillCliFields(
    comptime Struct: type,
    comptime prefix: []const u8,
    field_names: anytype,
    field_types: anytype,
    field_attrs: anytype,
    field_index: *usize,
) void {
    inline for (@typeInfo(Struct).@"struct".fields) |field| {
        if (comptime Struct == config.Config and std.mem.eql(u8, field.name, "storage")) {
            appendCliField(
                field_names,
                field_types,
                field_attrs,
                field_index,
                "storage_filesystem_path",
                []const u8,
            );
            continue;
        }

        const field_name = comptime concatNames(prefix, field.name);
        switch (@typeInfo(field.type)) {
            .@"struct" => {
                const nested_prefix = comptime appendNameSeparator(field_name[0..]);
                fillCliFields(
                    field.type,
                    nested_prefix[0..],
                    field_names,
                    field_types,
                    field_attrs,
                    field_index,
                );
            },
            .@"union" => @compileError("configuration union requires a custom CLI override"),
            else => appendCliField(
                field_names,
                field_types,
                field_attrs,
                field_index,
                field_name[0..],
                field.type,
            ),
        }
    }
}

fn appendCliField(
    field_names: anytype,
    field_types: anytype,
    field_attrs: anytype,
    field_index: *usize,
    comptime field_name: []const u8,
    comptime ConfigFieldType: type,
) void {
    const ValueType = switch (@typeInfo(ConfigFieldType)) {
        .optional => |optional| optional.child,
        else => ConfigFieldType,
    };
    const OverrideType = ?ValueType;
    const default_value: OverrideType = null;

    field_names[field_index.*] = field_name ++ "";
    field_types[field_index.*] = OverrideType;
    field_attrs[field_index.*] = .{ .default_value_ptr = @ptrCast(&default_value) };
    field_index.* += 1;
}

fn concatNames(comptime prefix: []const u8, comptime name: []const u8) [prefix.len + name.len]u8 {
    var result: [prefix.len + name.len]u8 = undefined;
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len..], name);
    return result;
}

fn appendNameSeparator(comptime name: []const u8) [name.len + 1]u8 {
    var result: [name.len + 1]u8 = undefined;
    @memcpy(result[0..name.len], name);
    result[name.len] = '_';
    return result;
}

pub fn load(allocator: std.mem.Allocator, sources: ConfigSources) !toml.Parsed(config.Config) {
    var parsed_config = try config.Config.parse(allocator, sources.toml);
    errdefer parsed_config.deinit();

    try applyEnvironment(parsed_config.arena.allocator(), &parsed_config.value, sources.envs);
    try applyCli(parsed_config.arena.allocator(), &parsed_config.value, sources.cli);
    try parsed_config.value.validate();
    return parsed_config;
}

pub fn loadFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    sources: ConfigSources,
) !toml.Parsed(config.Config) {
    const selected_path = if (sources.cli) |cli| cli.config_path orelse path else path;
    const explicitly_selected = if (sources.cli) |cli| cli.config_path != null else false;
    const config_file_contents: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(
        io,
        selected_path,
        allocator,
        .limited(1024 * 1024),
    ) catch |read_error| switch (read_error) {
        error.FileNotFound => if (explicitly_selected) return error.FileNotFound else null,
        else => return read_error,
    };
    defer if (config_file_contents) |contents| allocator.free(contents);

    var file_sources = sources;
    file_sources.toml = config_file_contents orelse "";
    return load(allocator, file_sources);
}

fn applyCli(
    allocator: std.mem.Allocator,
    app_config: *config.Config,
    overrides: ?CliOverrides,
) !void {
    const cli = overrides orelse return;
    try applyCliFields(allocator, app_config, cli, config.Config, "");
}

fn applyCliFields(
    allocator: std.mem.Allocator,
    target: anytype,
    cli: CliOverrides,
    comptime Struct: type,
    comptime prefix: []const u8,
) !void {
    inline for (@typeInfo(Struct).@"struct".fields) |field| {
        if (comptime Struct == config.Config and std.mem.eql(u8, field.name, "storage")) {
            if (cli.storage_filesystem_path) |path| {
                switch (@field(target.*, field.name)) {
                    .filesystem => |*filesystem| filesystem.path = try allocator.dupe(u8, path),
                }
            }
            continue;
        }

        const field_name = comptime concatNames(prefix, field.name);
        switch (@typeInfo(field.type)) {
            .@"struct" => {
                const nested_prefix = comptime appendNameSeparator(field_name[0..]);
                try applyCliFields(
                    allocator,
                    &@field(target.*, field.name),
                    cli,
                    field.type,
                    nested_prefix[0..],
                );
            },
            .@"union" => @compileError("configuration union requires a custom CLI override"),
            else => {
                if (@hasField(CliOverrides, field_name[0..])) {
                    try applyCliValue(
                        allocator,
                        &@field(target.*, field.name),
                        @field(cli, field_name[0..]),
                    );
                }
            },
        }
    }
}

fn applyCliValue(allocator: std.mem.Allocator, target: anytype, value: anytype) !void {
    if (value) |resolved| {
        const TargetType = @TypeOf(target.*);
        const ValueType = switch (@typeInfo(TargetType)) {
            .optional => |optional| optional.child,
            else => TargetType,
        };
        if (ValueType == []const u8) {
            target.* = try allocator.dupe(u8, resolved);
        } else {
            target.* = resolved;
        }
    }
}

fn applyEnvironment(
    allocator: std.mem.Allocator,
    app_config: *config.Config,
    environ_map: ?*const std.process.Environ.Map,
) !void {
    try applyEnvironmentStruct(allocator, app_config, environ_map, "VERSO_");

    if (environment.get(environ_map, "VERSO_STORAGE_FS_PATH")) |asset_path| {
        switch (app_config.storage) {
            .filesystem => |*filesystem| filesystem.path = try allocator.dupe(u8, asset_path),
        }
    }
}

fn applyEnvironmentStruct(
    allocator: std.mem.Allocator,
    target: anytype,
    environ_map: ?*const std.process.Environ.Map,
    comptime prefix: []const u8,
) !void {
    const Target = @TypeOf(target);
    const Struct = @typeInfo(Target).pointer.child;

    inline for (@typeInfo(Struct).@"struct".fields) |field| {
        // The storage union has a deliberately stable, custom environment
        // variable name: VERSO_STORAGE_FS_PATH.
        if (comptime Struct == config.Config and std.mem.eql(u8, field.name, "storage")) continue;

        const environment_name = comptime makeEnvironmentName(prefix, field.name);
        const field_target = &@field(target.*, field.name);

        switch (@typeInfo(field.type)) {
            .@"struct" => {
                const nested_prefix = comptime std.fmt.comptimePrint("{s}_", .{environment_name});
                try applyEnvironmentStruct(allocator, field_target, environ_map, nested_prefix);
            },
            .@"union" => @compileError("configuration union requires a custom environment override"),
            else => try overrideValue(allocator, environ_map, environment_name[0..], field_target),
        }
    }
}

fn makeEnvironmentName(comptime prefix: []const u8, comptime field_name: []const u8) [prefix.len + field_name.len]u8 {
    var result: [prefix.len + field_name.len]u8 = undefined;
    @memcpy(result[0..prefix.len], prefix);
    inline for (field_name, 0..) |character, index| {
        result[prefix.len + index] = std.ascii.toUpper(character);
    }
    return result;
}

fn overrideValue(
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    name: []const u8,
    target: anytype,
) !void {
    const T = @TypeOf(target.*);

    if (T == bool) {
        return overrideBool(environ_map, name, target);
    }
    if (T == []const u8 or T == ?[]const u8) {
        return overrideString(allocator, environ_map, name, target);
    }

    switch (@typeInfo(T)) {
        .int => |int| {
            if (int.signedness != .unsigned) {
                @compileError("environment overrides only support unsigned integer fields");
            }
            return overrideUnsigned(T, environ_map, name, target);
        },
        .@"enum" => return overrideEnum(T, environ_map, name, target),
        else => @compileError("configuration field requires a custom environment override"),
    }
}

fn overrideString(
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    name: []const u8,
    target: anytype,
) !void {
    if (environment.get(environ_map, name)) |environment_text| {
        target.* = try allocator.dupe(u8, environment_text);
    }
}

fn overrideEnum(
    comptime T: type,
    environ_map: ?*const std.process.Environ.Map,
    name: []const u8,
    target: *T,
) !void {
    if (environment.get(environ_map, name)) |environment_text| {
        target.* = environment.parseEnum(T, environment_text) catch return error.InvalidEnvironmentValue;
    }
}

fn overrideUnsigned(
    comptime T: type,
    environ_map: ?*const std.process.Environ.Map,
    name: []const u8,
    target: *T,
) !void {
    if (environment.get(environ_map, name)) |environment_text| {
        target.* = environment.parseUnsigned(T, environment_text) catch return error.InvalidEnvironmentValue;
    }
}

fn overrideBool(
    environ_map: ?*const std.process.Environ.Map,
    name: []const u8,
    target: *bool,
) !void {
    if (environment.get(environ_map, name)) |environment_text| {
        target.* = environment.parseBool(environment_text) catch return error.InvalidEnvironmentValue;
    }
}
