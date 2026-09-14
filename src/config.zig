const std = @import("std");
const toml = @import("toml");
const defaults = @import("config/defaults.zig");
const environment = @import("config/environment.zig");
const validation = @import("config/validation.zig");

pub const ConfigError = error{
    InvalidSiteName,
    InvalidBaseUrl,
    MissingBaseUrl,
    InvalidServerHost,
    InvalidDatabaseUrl,
    InvalidStoragePath,
    InvalidCachePath,
    InvalidTheme,
    InvalidLogoPath,
    UnsupportedLogoVariant,
    InvalidFeatureConfiguration,
    InvalidEditorConfiguration,
    InvalidMcpConfiguration,
    InvalidEnvironmentValue,
};

pub const Environment = enum {
    development,
    production,
};

pub const UiLanguage = enum {
    en,
};

pub const Config = struct {
    runtime: Runtime = .{},
    site: Site = .{},
    server: Server = .{},
    database: Database = .{},
    storage: Storage = .{ .filesystem = .{} },
    cache: Cache = .{},
    ui: Ui = .{},
    features: Features = .{},
    editor: Editor = .{},
    mcp: Mcp = .{},

    pub const Runtime = struct {
        environment: Environment = .development,
    };

    pub const Site = struct {
        name: []const u8 = "Verso",
        base_url: ?[]const u8 = null,
    };

    pub const Server = struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 8080,
    };

    pub const Database = struct {
        url: []const u8 = "./data/verso.db",
    };

    pub const Storage = union(enum) {
        filesystem: Filesystem,

        pub const Filesystem = struct {
            path: []const u8 = "./data/assets",
        };
    };

    pub const Cache = struct {
        path: []const u8 = "./data/cache",
    };

    pub const Ui = struct {
        language: UiLanguage = .en,
        theme: []const u8 = "default",
        logo: ?[]const u8 = null,
        icon: ?[]const u8 = null,
        logo_wordmark: ?[]const u8 = null,
    };

    pub const Features = struct {
        math: bool = true,
        interactive_sections: bool = false,
    };

    pub const Editor = struct {
        local_preview_debounce_ms: u32 = 500,
    };

    pub const Mcp = struct {
        enabled: bool = true,
        allow_publish: bool = false,
    };

    pub fn parse(allocator: std.mem.Allocator, input: []const u8) !toml.Parsed(Config) {
        var parser = toml.Parser(Config).init(allocator);
        defer parser.deinit();

        var parsed = try parser.parseString(input);
        errdefer parsed.deinit();
        try parsed.value.validate();
        return parsed;
    }

    pub fn writeDefault(writer: *std.Io.Writer) !void {
        try defaults.write(writer);
    }

    pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !toml.Parsed(Config) {
        return loadWithEnv(io, allocator, path, null);
    }

    pub fn loadOptional(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !toml.Parsed(Config) {
        return loadWithEnvOptional(io, allocator, path, null);
    }

    pub fn loadWithEnv(
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
        environ_map: ?*const std.process.Environ.Map,
    ) !toml.Parsed(Config) {
        return loadWithEnvInternal(io, allocator, path, environ_map, false);
    }

    pub fn loadWithEnvOptional(
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
        environ_map: ?*const std.process.Environ.Map,
    ) !toml.Parsed(Config) {
        return loadWithEnvInternal(io, allocator, path, environ_map, true);
    }

    fn loadWithEnvInternal(
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
        environ_map: ?*const std.process.Environ.Map,
        allow_missing: bool,
    ) !toml.Parsed(Config) {
        var parser = toml.Parser(Config).init(allocator);
        defer parser.deinit();

        var parsed = parser.parseFile(io, path) catch |err| switch (err) {
            error.FileNotFound => if (allow_missing) try parser.parseString("") else return err,
            else => return err,
        };
        errdefer parsed.deinit();
        try applyEnvironment(parsed.arena.allocator(), &parsed.value, environ_map);
        try parsed.value.validate();
        return parsed;
    }

    pub fn applyEnvironment(
        allocator: std.mem.Allocator,
        self: *Config,
        environ_map: ?*const std.process.Environ.Map,
    ) !void {
        try overrideEnum(Environment, environ_map, "VERSO_RUNTIME_ENVIRONMENT", &self.runtime.environment);
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

        try overrideEnum(UiLanguage, environ_map, "VERSO_UI_LANGUAGE", &self.ui.language);
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

    pub fn validate(self: Config) ConfigError!void {
        if (!validation.isSafeText(self.site.name)) return error.InvalidSiteName;
        if (!validation.isValidServerHost(self.server.host)) return error.InvalidServerHost;
        if (self.server.port == 0) return error.InvalidServerHost;

        if (self.site.base_url) |base_url| {
            if (!validation.isValidBaseUrl(base_url)) return error.InvalidBaseUrl;
            if (self.runtime.environment == .production and validation.isLoopbackBaseUrl(base_url)) {
                return error.InvalidBaseUrl;
            }
        } else if (self.runtime.environment == .production or
            !validation.isLoopbackHost(self.server.host))
        {
            return error.MissingBaseUrl;
        }

        if (!validation.isValidDatabaseUrl(self.database.url)) return error.InvalidDatabaseUrl;

        switch (self.storage) {
            .filesystem => |filesystem| {
                if (!validation.isValidPath(filesystem.path)) return error.InvalidStoragePath;
            },
        }
        if (!validation.isValidPath(self.cache.path)) return error.InvalidCachePath;

        if (!validation.isSafeToken(self.ui.theme)) return error.InvalidTheme;
        if (self.ui.logo) |logo| {
            if (!validation.isValidPath(logo)) return error.InvalidLogoPath;
        }
        if (self.ui.icon) |icon| {
            if (!validation.isValidPath(icon)) return error.InvalidLogoPath;
            return error.UnsupportedLogoVariant;
        }
        if (self.ui.logo_wordmark) |logo_wordmark| {
            if (!validation.isValidPath(logo_wordmark)) return error.InvalidLogoPath;
            return error.UnsupportedLogoVariant;
        }

        if (self.editor.local_preview_debounce_ms == 0) {
            return error.InvalidEditorConfiguration;
        }
        if (self.mcp.allow_publish and !self.mcp.enabled) {
            return error.InvalidMcpConfiguration;
        }
        if (self.features.interactive_sections) {
            return error.InvalidFeatureConfiguration;
        }
    }

    pub fn effectiveBaseUrl(self: Config, buffer: []u8) ![]const u8 {
        if (self.site.base_url) |base_url| return base_url;
        if (std.mem.indexOfScalar(u8, self.server.host, ':') != null) {
            return std.fmt.bufPrint(buffer, "http://[{s}]:{}", .{ self.server.host, self.server.port });
        }
        return std.fmt.bufPrint(buffer, "http://{s}:{}", .{ self.server.host, self.server.port });
    }

    pub fn uiLanguageTag(self: Config) []const u8 {
        return @tagName(self.ui.language);
    }
};

test "parses and validates a complete configuration" {
    const input =
        \\[runtime]
        \\environment = 'production'
        \\
        \\[site]
        \\name = 'Example Publication'
        \\base_url = 'https://example.org'
        \\
        \\[server]
        \\host = '127.0.0.1'
        \\port = 9090
        \\
        \\[database]
        \\url = './data/verso.db'
        \\
        \\[storage.filesystem]
        \\path = './data/assets'
        \\
        \\[cache]
        \\path = './data/cache'
        \\
        \\[ui]
        \\language = 'en'
        \\theme = 'default'
        \\logo = '/assets/logo.svg'
        \\
        \\[features]
        \\math = true
        \\interactive_sections = false
        \\
        \\[editor]
        \\local_preview_debounce_ms = 500
        \\
        \\[mcp]
        \\enabled = true
        \\allow_publish = false
    ;

    var parsed = try Config.parse(std.testing.allocator, input);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Example Publication", parsed.value.site.name);
    try std.testing.expectEqual(Environment.production, parsed.value.runtime.environment);
    try std.testing.expectEqual(UiLanguage.en, parsed.value.ui.language);
    try std.testing.expectEqualStrings("en", parsed.value.uiLanguageTag());
    try std.testing.expectEqual(@as(u16, 9090), parsed.value.server.port);
    try std.testing.expectEqual(@as(u32, 500), parsed.value.editor.local_preview_debounce_ms);
    switch (parsed.value.storage) {
        .filesystem => |filesystem| try std.testing.expectEqualStrings("./data/assets", filesystem.path),
    }
}

test "default configuration output is valid TOML" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try Config.writeDefault(&writer);

    var parsed = try Config.parse(std.testing.allocator, writer.buffered());
    defer parsed.deinit();
    try std.testing.expectEqual(Environment.development, parsed.value.runtime.environment);
    try std.testing.expectEqualStrings("Verso", parsed.value.site.name);
}

test "development derives a loopback base URL" {
    var parsed = try Config.parse(std.testing.allocator, "");
    defer parsed.deinit();

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", try parsed.value.effectiveBaseUrl(&buffer));
}

test "development brackets expanded IPv6 loopback URLs" {
    var parsed = try Config.parse(
        std.testing.allocator,
        "[server]\nhost = '0:0:0:0:0:0:0:1'\nport = 9090\n",
    );
    defer parsed.deinit();

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://[0:0:0:0:0:0:0:1]:9090",
        try parsed.value.effectiveBaseUrl(&buffer),
    );
}

test "production requires an explicit public base URL" {
    try std.testing.expectError(
        error.MissingBaseUrl,
        Config.parse(std.testing.allocator, "[runtime]\nenvironment = 'production'\n"),
    );
    try std.testing.expectError(
        error.InvalidBaseUrl,
        Config.parse(std.testing.allocator, "[runtime]\nenvironment = 'production'\n[site]\nbase_url = 'http://127.0.0.1:8080'\n"),
    );
}

test "unsupported UI logo variants are rejected after parsing" {
    try std.testing.expectError(
        error.UnsupportedLogoVariant,
        Config.parse(std.testing.allocator, "[ui]\nicon = '/assets/icon.svg'\n"),
    );
}

test "unsupported UI languages are rejected by TOML enum mapping" {
    try std.testing.expectError(
        error.InvalidValueType,
        Config.parse(std.testing.allocator, "[ui]\nlanguage = 'xx'\n"),
    );
}

test "unsafe configuration is rejected" {
    try std.testing.expectError(
        error.InvalidFeatureConfiguration,
        Config.parse(std.testing.allocator, "[features]\ninteractive_sections = true\n"),
    );
    try std.testing.expectError(
        error.InvalidDatabaseUrl,
        Config.parse(std.testing.allocator, "[database]\nurl = './data/../secrets.db'\n"),
    );
}

test "loads a configuration file" {
    var parsed = try Config.load(std.testing.io, std.testing.allocator, "testdata/verso.toml");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Example Publication", parsed.value.site.name);
    try std.testing.expectEqual(UiLanguage.en, parsed.value.ui.language);
    switch (parsed.value.storage) {
        .filesystem => |filesystem| try std.testing.expectEqualStrings("./data/assets", filesystem.path),
    }
}

test "optional configuration falls back to built-in defaults" {
    var parsed = try Config.loadOptional(std.testing.io, std.testing.allocator, "testdata/missing-verso.toml");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Verso", parsed.value.site.name);
    try std.testing.expectEqual(@as(u16, 8080), parsed.value.server.port);
    try std.testing.expectEqualStrings("./data/verso.db", parsed.value.database.url);
}

test "environment overrides take precedence over TOML" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("VERSO_SITE_NAME", "Environment Publication");
    try environ.put("VERSO_SITE_BASE_URL", "https://environment.example");
    try environ.put("VERSO_SERVER_PORT", "9090");
    try environ.put("VERSO_DATABASE_URL", "./data/environment.db");
    try environ.put("VERSO_STORAGE_FS_PATH", "./data/environment-assets");
    try environ.put("VERSO_FEATURES_MATH", "false");
    try environ.put("VERSO_EDITOR_LOCAL_PREVIEW_DEBOUNCE_MS", "750");

    var parsed = try Config.loadWithEnv(
        std.testing.io,
        std.testing.allocator,
        "testdata/verso.toml",
        &environ,
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Environment Publication", parsed.value.site.name);
    try std.testing.expectEqualStrings("https://environment.example", parsed.value.site.base_url.?);
    try std.testing.expectEqual(@as(u16, 9090), parsed.value.server.port);
    try std.testing.expectEqualStrings("./data/environment.db", parsed.value.database.url);
    try std.testing.expectEqual(false, parsed.value.features.math);
    try std.testing.expectEqual(@as(u32, 750), parsed.value.editor.local_preview_debounce_ms);
    switch (parsed.value.storage) {
        .filesystem => |filesystem| try std.testing.expectEqualStrings("./data/environment-assets", filesystem.path),
    }
}

test "environment overrides reject invalid typed values" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("VERSO_SERVER_PORT", "not-a-port");

    var parsed = try Config.parse(std.testing.allocator, "");
    defer parsed.deinit();
    try std.testing.expectError(
        error.InvalidEnvironmentValue,
        Config.applyEnvironment(parsed.arena.allocator(), &parsed.value, &environ),
    );
}

test "unknown environment variables do not change configuration" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("VERSO_UNKNOWN_SETTING", "unexpected");

    var parsed = try Config.parse(std.testing.allocator, "");
    defer parsed.deinit();
    try Config.applyEnvironment(parsed.arena.allocator(), &parsed.value, &environ);
    try parsed.value.validate();
    try std.testing.expectEqualStrings("Verso", parsed.value.site.name);
}

test "environment overrides cannot bypass production base URL requirements" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("VERSO_RUNTIME_ENVIRONMENT", "production");

    var parsed = try Config.parse(std.testing.allocator, "");
    defer parsed.deinit();
    try Config.applyEnvironment(parsed.arena.allocator(), &parsed.value, &environ);
    try std.testing.expectError(error.MissingBaseUrl, parsed.value.validate());
}
