const std = @import("std");
const toml = @import("toml");
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

    pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !toml.Parsed(Config) {
        var parser = toml.Parser(Config).init(allocator);
        defer parser.deinit();

        var parsed = try parser.parseFile(io, path);
        errdefer parsed.deinit();
        try parsed.value.validate();
        return parsed;
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
