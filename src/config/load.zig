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
    var parsed = try config.Config.parse(allocator, sources.toml);
    errdefer parsed.deinit();

    try applyEnvironment(parsed.arena.allocator(), &parsed.value, sources.envs);
    try applyArgs(&parsed.value, sources.args);
    try parsed.value.validate();
    return parsed;
}

pub fn loadFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    sources: ConfigSources,
) !toml.Parsed(config.Config) {
    const owned_input: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (owned_input) |input| allocator.free(input);

    var file_sources = sources;
    file_sources.toml = owned_input orelse "";
    return load(allocator, file_sources);
}

fn applyArgs(self: *config.Config, args: ?*std.process.Args.Iterator) !void {
    _ = self;
    _ = args;
}

fn applyEnvironment(
    allocator: std.mem.Allocator,
    self: *config.Config,
    environ_map: ?*const std.process.Environ.Map,
) !void {
    try overrideEnum(config.Environment, environ_map, "VERSO_RUNTIME_ENVIRONMENT", &self.runtime.environment);
    try overrideEnum(config.LoggingFormat, environ_map, "VERSO_LOGGING_FORMAT", &self.logging.format);
    try overrideString(allocator, environ_map, "VERSO_SITE_NAME", &self.site.name);
    try overrideString(allocator, environ_map, "VERSO_SITE_BASE_URL", &self.site.base_url);
    try overrideString(allocator, environ_map, "VERSO_SERVER_HOST", &self.server.host);
    try overrideUnsigned(u16, environ_map, "VERSO_SERVER_PORT", &self.server.port);
    try overrideString(allocator, environ_map, "VERSO_DATABASE_URL", &self.database.url);

    if (environment.get(environ_map, "VERSO_STORAGE_FS_PATH")) |value| {
        switch (self.storage) {
            .filesystem => |*filesystem| filesystem.path = try allocator.dupe(u8, value),
        }
    }
    try overrideString(allocator, environ_map, "VERSO_CACHE_PATH", &self.cache.path);

    try overrideEnum(config.UiLanguage, environ_map, "VERSO_UI_LANGUAGE", &self.ui.language);
    try overrideString(allocator, environ_map, "VERSO_UI_THEME", &self.ui.theme);
    try overrideString(allocator, environ_map, "VERSO_UI_LOGO", &self.ui.logo);
    try overrideString(allocator, environ_map, "VERSO_UI_ICON", &self.ui.icon);
    try overrideString(allocator, environ_map, "VERSO_UI_LOGO_WORDMARK", &self.ui.logo_wordmark);

    try overrideBool(environ_map, "VERSO_FEATURES_MATH", &self.features.math);
    try overrideBool(environ_map, "VERSO_FEATURES_INTERACTIVE_SECTIONS", &self.features.interactive_sections);
    try overrideUnsigned(u32, environ_map, "VERSO_EDITOR_LOCAL_PREVIEW_DEBOUNCE_MS", &self.editor.local_preview_debounce_ms);
    try overrideBool(environ_map, "VERSO_MCP_ENABLED", &self.mcp.enabled);
    try overrideBool(environ_map, "VERSO_MCP_ALLOW_PUBLISH", &self.mcp.allow_publish);
}

fn overrideString(
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    name: []const u8,
    target: anytype,
) !void {
    if (environment.get(environ_map, name)) |value| {
        target.* = try allocator.dupe(u8, value);
    }
}

fn overrideEnum(
    comptime T: type,
    environ_map: ?*const std.process.Environ.Map,
    name: []const u8,
    target: *T,
) !void {
    if (environment.get(environ_map, name)) |value| {
        target.* = environment.parseEnum(T, value) catch return error.InvalidEnvironmentValue;
    }
}

fn overrideUnsigned(
    comptime T: type,
    environ_map: ?*const std.process.Environ.Map,
    name: []const u8,
    target: *T,
) !void {
    if (environment.get(environ_map, name)) |value| {
        target.* = environment.parseUnsigned(T, value) catch return error.InvalidEnvironmentValue;
    }
}

fn overrideBool(
    environ_map: ?*const std.process.Environ.Map,
    name: []const u8,
    target: *bool,
) !void {
    if (environment.get(environ_map, name)) |value| {
        target.* = environment.parseBool(value) catch return error.InvalidEnvironmentValue;
    }
}
