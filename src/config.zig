const std = @import("std");
const toml = @import("toml");
const validation = @import("config/validation.zig");

pub const ConfigError = error{
    InvalidSiteName,
    InvalidBaseUrl,
    InvalidServerHost,
    InvalidDatabasePath,
    InvalidStorageType,
    InvalidStoragePath,
    InvalidCachePath,
    InvalidTheme,
    InvalidLogoPath,
    InvalidFeatureConfiguration,
    InvalidEditorConfiguration,
    InvalidMcpConfiguration,
};

pub const Config = struct {
    site: Site = .{},
    server: Server = .{},
    database: Database = .{},
    storage: Storage = .{},
    cache: Cache = .{},
    ui: Ui = .{},
    features: Features = .{},
    editor: Editor = .{},
    mcp: Mcp = .{},

    pub const Site = struct {
        name: []const u8 = "Verso",
        base_url: []const u8 = "http://127.0.0.1:8080",
        language: []const u8 = "en",
    };

    pub const Server = struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 8080,
    };

    pub const Database = struct {
        path: []const u8 = "./data/verso.db",
    };

    pub const Storage = struct {
        type: StorageType = .filesystem,
        path: []const u8 = "./data/assets",
    };

    pub const StorageType = enum {
        filesystem,
    };

    pub const Cache = struct {
        path: []const u8 = "./data/cache",
    };

    pub const Ui = struct {
        theme: []const u8 = "default",
        logo: ?[]const u8 = null,
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
        if (!validation.isSafeText(self.site.language)) return error.InvalidSiteName;
        if (!validation.isValidBaseUrl(self.site.base_url)) return error.InvalidBaseUrl;

        if (!validation.isValidServerHost(self.server.host)) return error.InvalidServerHost;
        if (self.server.port == 0) return error.InvalidServerHost;

        if (!validation.isSafePath(self.database.path)) return error.InvalidDatabasePath;
        if (!validation.isSafePath(self.storage.path)) return error.InvalidStoragePath;
        if (self.storage.type != .filesystem) return error.InvalidStorageType;
        if (!validation.isSafePath(self.cache.path)) return error.InvalidCachePath;

        if (!validation.isSafeToken(self.ui.theme)) return error.InvalidTheme;
        if (self.ui.logo) |logo| {
            if (!validation.isSafePath(logo)) return error.InvalidLogoPath;
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
};

test "parses and validates a complete configuration" {
    const input =
        "[site]\n" ++
        "name = 'Example Publication'\n" ++
        "base_url = 'https://example.org'\n" ++
        "language = 'en'\n\n" ++
        "[server]\n" ++
        "host = '127.0.0.1'\n" ++
        "port = 9090\n\n" ++
        "[database]\n" ++
        "path = './data/verso.db'\n\n" ++
        "[storage]\n" ++
        "type = 'filesystem'\n" ++
        "path = './data/assets'\n\n" ++
        "[cache]\n" ++
        "path = './data/cache'\n\n" ++
        "[ui]\n" ++
        "theme = 'default'\n" ++
        "logo = '/assets/logo.svg'\n\n" ++
        "[features]\n" ++
        "math = true\n" ++
        "interactive_sections = false\n\n" ++
        "[editor]\n" ++
        "local_preview_debounce_ms = 500\n\n" ++
        "[mcp]\n" ++
        "enabled = true\n" ++
        "allow_publish = false\n";

    var parsed = try Config.parse(std.testing.allocator, input);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Example Publication", parsed.value.site.name);
    try std.testing.expectEqual(@as(u16, 9090), parsed.value.server.port);
    try std.testing.expectEqual(@as(u32, 500), parsed.value.editor.local_preview_debounce_ms);
}

test "defaults apply to an empty configuration" {
    var parsed = try Config.parse(std.testing.allocator, "");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Verso", parsed.value.site.name);
    try std.testing.expectEqual(@as(u16, 8080), parsed.value.server.port);
}

test "unsafe configuration is rejected" {
    try std.testing.expectError(
        error.InvalidFeatureConfiguration,
        Config.parse(std.testing.allocator, "[features]\ninteractive_sections = true\n"),
    );
    try std.testing.expectError(
        error.InvalidBaseUrl,
        Config.parse(std.testing.allocator, "[site]\nbase_url = 'javascript:alert(1)'\n"),
    );
}

test "loads a configuration file" {
    var parsed = try Config.load(std.testing.io, std.testing.allocator, "testdata/verso.toml");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Example Publication", parsed.value.site.name);
}
