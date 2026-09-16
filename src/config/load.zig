const std = @import("std");
const toml = @import("toml");
const config = @import("types.zig");
const environment = @import("environment.zig");

pub const ConfigSources = struct {
    toml: []const u8 = "",
    envs: ?*const std.process.Environ.Map = null,
    args: ?*std.process.Args.Iterator = null,
};

pub fn load(allocator: std.mem.Allocator, sources: ConfigSources) !toml.Parsed(config.Config) {
    var parsed_config = try config.Config.parse(allocator, sources.toml);
    errdefer parsed_config.deinit();

    try applyEnvironment(parsed_config.arena.allocator(), &parsed_config.value, sources.envs);
    try applyArgs(&parsed_config.value, sources.args);
    try parsed_config.value.validate();
    return parsed_config;
}

pub fn loadFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    sources: ConfigSources,
) !toml.Parsed(config.Config) {
    const config_file_contents: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(1024 * 1024),
    ) catch |read_error| switch (read_error) {
        error.FileNotFound => null,
        else => return read_error,
    };
    defer if (config_file_contents) |contents| allocator.free(contents);

    var file_sources = sources;
    file_sources.toml = config_file_contents orelse "";
    return load(allocator, file_sources);
}

fn applyArgs(app_config: *config.Config, command_args: ?*std.process.Args.Iterator) !void {
    _ = app_config;
    _ = command_args;
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
