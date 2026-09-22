const std = @import("std");
const toml = @import("toml");
const config = @import("types.zig");
const environment = @import("environment.zig");
const schema = @import("schema.zig");

pub const ConfigSources = struct {
    toml: []const u8 = "",
    envs: ?*const std.process.Environ.Map = null,
    cli: ?CliOverrides = null,
};

pub const CliOverrides = makeCliOverrides();

fn makeCliOverrides() type {
    const field_count = 1 + cliFieldCount();
    var field_names: [field_count][]const u8 = undefined;
    var field_types: [field_count]type = undefined;
    var field_attrs: [field_count]std.builtin.Type.StructField.Attributes = @splat(.{});
    var field_index: usize = 0;

    appendCliField(&field_names, &field_types, &field_attrs, &field_index, "config_path", []const u8);
    fillCliFields(&field_names, &field_types, &field_attrs, &field_index);

    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

fn cliFieldCount() usize {
    var count: usize = 0;
    inline for (schema.serve_cli_metadata) |metadata| {
        if (metadata.cli_enabled) count += 1;
    }
    return count;
}

fn fillCliFields(
    field_names: anytype,
    field_types: anytype,
    field_attrs: anytype,
    field_index: *usize,
) void {
    inline for (schema.serve_cli_metadata) |metadata| {
        if (metadata.cli_enabled) {
            const field_name = schema.cliName(metadata.config_field);
            appendCliField(
                field_names,
                field_types,
                field_attrs,
                field_index,
                field_name[0..],
                schema.fieldType(metadata.config_field),
            );
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

pub fn load(allocator: std.mem.Allocator, sources: ConfigSources) !toml.Parsed(config.Config) {
    var parsed_config = try config.Config.parse(allocator, sources.toml);
    errdefer parsed_config.deinit();

    try applyEnvironment(parsed_config.arena.allocator(), &parsed_config.value, sources.envs);
    try applyCli(parsed_config.arena.allocator(), &parsed_config.value, sources.cli);
    try parsed_config.value.validateWithAllocator(parsed_config.arena.allocator());
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
    inline for (schema.serve_cli_metadata) |metadata| {
        if (metadata.cli_enabled) {
            const field_name = comptime schema.cliName(metadata.config_field);
            if (@field(cli, field_name[0..])) |value| {
                try applyCliPath(allocator, app_config, metadata.config_field, value);
            }
        }
    }
}

fn applyCliPath(
    allocator: std.mem.Allocator,
    target: anytype,
    comptime path: []const u8,
    value: anytype,
) !void {
    const head = comptime pathHead(path);
    const tail = comptime pathTail(path);
    const field_target = &@field(target.*, head);
    if (tail.len == 0) {
        return applyCliValue(allocator, field_target, value);
    }

    switch (@typeInfo(@TypeOf(field_target.*))) {
        .@"struct" => try applyCliPath(allocator, field_target, tail, value),
        .@"union" => try applyUnionCliPath(allocator, field_target, tail, value),
        else => @compileError("configuration CLI path traverses a non-container field"),
    }
}

fn applyUnionCliPath(
    allocator: std.mem.Allocator,
    target: anytype,
    comptime path: []const u8,
    value: anytype,
) !void {
    if (@TypeOf(target.*) != config.Config.Storage) {
        @compileError("configuration union requires an explicit CLI mapping");
    }
    const tail = comptime pathTail(path);
    switch (target.*) {
        .filesystem => |*filesystem| try applyCliPath(allocator, filesystem, tail, value),
    }
}

fn pathHead(comptime path: []const u8) []const u8 {
    return path[0 .. std.mem.indexOfScalar(u8, path, '.') orelse path.len];
}

fn pathTail(comptime path: []const u8) []const u8 {
    const separator = std.mem.indexOfScalar(u8, path, '.') orelse return "";
    return path[separator + 1 ..];
}

fn applyCliValue(allocator: std.mem.Allocator, target: anytype, value: anytype) !void {
    const TargetType = @TypeOf(target.*);
    const ValueType = switch (@typeInfo(TargetType)) {
        .optional => |optional| optional.child,
        else => TargetType,
    };
    if (ValueType == []const u8) {
        target.* = try allocator.dupe(u8, value);
    } else {
        target.* = value;
    }
}

fn applyEnvironment(
    allocator: std.mem.Allocator,
    app_config: *config.Config,
    environ_map: ?*const std.process.Environ.Map,
) !void {
    inline for (schema.environment_fields) |field| {
        try applyEnvironmentPath(
            allocator,
            app_config,
            field.config_field,
            field.environment_name,
            environ_map,
        );
    }
}

fn applyEnvironmentPath(
    allocator: std.mem.Allocator,
    target: anytype,
    comptime path: []const u8,
    name: []const u8,
    environ_map: ?*const std.process.Environ.Map,
) !void {
    const head = comptime pathHead(path);
    const tail = comptime pathTail(path);
    const field_target = &@field(target.*, head);
    if (tail.len == 0) {
        return overrideValue(allocator, environ_map, name, field_target);
    }

    switch (@typeInfo(@TypeOf(field_target.*))) {
        .@"struct" => try applyEnvironmentPath(allocator, field_target, tail, name, environ_map),
        .@"union" => try applyUnionEnvironmentPath(
            allocator,
            field_target,
            tail,
            name,
            environ_map,
        ),
        else => @compileError("configuration environment path traverses a non-container field"),
    }
}

fn applyUnionEnvironmentPath(
    allocator: std.mem.Allocator,
    target: anytype,
    comptime path: []const u8,
    name: []const u8,
    environ_map: ?*const std.process.Environ.Map,
) !void {
    if (@TypeOf(target.*) != config.Config.Storage) {
        @compileError("configuration union requires an explicit environment mapping");
    }
    const tail = comptime pathTail(path);
    switch (target.*) {
        .filesystem => |*filesystem| try applyEnvironmentPath(
            allocator,
            filesystem,
            tail,
            name,
            environ_map,
        ),
    }
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
