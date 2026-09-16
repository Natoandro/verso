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
    try overrideEnum(config.Environment, environ_map, "VERSO_RUNTIME_ENVIRONMENT", &app_config.runtime.environment);
    try overrideEnum(config.LoggingFormat, environ_map, "VERSO_LOGGING_FORMAT", &app_config.logging.format);
    try overrideBool(environ_map, "VERSO_LOGGING_OMIT_NULL_FIELDS", &app_config.logging.omit_null_fields);
    try overrideString(allocator, environ_map, "VERSO_SITE_NAME", &app_config.site.name);
    try overrideString(allocator, environ_map, "VERSO_SITE_BASE_URL", &app_config.site.base_url);
    try overrideString(allocator, environ_map, "VERSO_SERVER_HOST", &app_config.server.host);
    try overrideUnsigned(u16, environ_map, "VERSO_SERVER_PORT", &app_config.server.port);
    try overrideString(allocator, environ_map, "VERSO_DATABASE_URL", &app_config.database.url);

    if (environment.get(environ_map, "VERSO_STORAGE_FS_PATH")) |asset_path| {
        switch (app_config.storage) {
            .filesystem => |*filesystem| filesystem.path = try allocator.dupe(u8, asset_path),
        }
    }
    try overrideString(allocator, environ_map, "VERSO_CACHE_PATH", &app_config.cache.path);

    try overrideEnum(config.UiLanguage, environ_map, "VERSO_UI_LANGUAGE", &app_config.ui.language);
    try overrideString(allocator, environ_map, "VERSO_UI_THEME", &app_config.ui.theme);
    try overrideString(allocator, environ_map, "VERSO_UI_LOGO", &app_config.ui.logo);
    try overrideString(allocator, environ_map, "VERSO_UI_ICON", &app_config.ui.icon);
    try overrideString(allocator, environ_map, "VERSO_UI_LOGO_WORDMARK", &app_config.ui.logo_wordmark);

    try overrideBool(environ_map, "VERSO_FEATURES_MATH", &app_config.features.math);
    try overrideBool(environ_map, "VERSO_FEATURES_INTERACTIVE_SECTIONS", &app_config.features.interactive_sections);
    try overrideUnsigned(u32, environ_map, "VERSO_EDITOR_LOCAL_PREVIEW_DEBOUNCE_MS", &app_config.editor.local_preview_debounce_ms);
    try overrideBool(environ_map, "VERSO_MCP_ENABLED", &app_config.mcp.enabled);
    try overrideBool(environ_map, "VERSO_MCP_ALLOW_PUBLISH", &app_config.mcp.allow_publish);
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
