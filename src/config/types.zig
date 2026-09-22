const std = @import("std");
const toml = @import("toml");
const defaults = @import("defaults.zig");
const logging = @import("../logging.zig");
const validation = @import("validation.zig");
const auth_identity = @import("../auth/identity.zig");
const auth_password = @import("../auth/password.zig");

pub const ConfigError = error{
    InvalidSiteName,
    InvalidBaseUrl,
    MissingBaseUrl,
    InvalidServerHost,
    InvalidDatabaseUrl,
    InvalidMigrationConfiguration,
    InvalidStoragePath,
    InvalidCachePath,
    InvalidPublicStaticPath,
    InvalidTheme,
    InvalidLogoPath,
    UnsupportedLogoVariant,
    InvalidFeatureConfiguration,
    InvalidEditorConfiguration,
    InvalidMcpConfiguration,
    InvalidSecurityConfiguration,
    InvalidAuthConfiguration,
    InvalidEnvironmentValue,
};

pub const Environment = enum {
    development,
    production,
};

pub const UiLanguage = enum {
    en,
};

pub const LoggingFormat = logging.Format;
pub const ResolvedLoggingFormat = logging.ResolvedFormat;

pub const Config = struct {
    runtime: Runtime = .{},
    logging: Logging = .{},
    site: Site = .{},
    server: Server = .{},
    security: Security = .{},
    auth: Auth = .{},
    database: Database = .{},
    migrations: Migrations = .{},
    public_static_root: ?[]const u8 = null,
    storage: Storage = .{ .filesystem = .{} },
    cache: Cache = .{},
    ui: Ui = .{},
    features: Features = .{},
    mcp: Mcp = .{},

    pub const Runtime = struct {
        environment: Environment = .development,
    };

    pub const Logging = struct {
        format: logging.Format = .auto,
        omit_null_fields: bool = true,
    };

    pub const Site = struct {
        name: []const u8 = "Verso",
        base_url: ?[]const u8 = null,
    };

    pub const Server = struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 8080,
    };

    pub const Security = struct {
        /// Comma-separated peer addresses allowed to supply forwarded headers.
        trusted_proxy_addresses: []const u8 = "",
    };

    pub const Auth = struct {
        bootstrap: Bootstrap = .{},
    };

    pub const Bootstrap = struct {
        display_name: ?[]const u8 = null,
        email: ?[]const u8 = null,
        subject: ?[]const u8 = null,
        login: ?[]const u8 = null,
        password_hash: ?[]const u8 = null,

        pub fn isConfigured(self: Bootstrap) bool {
            return self.display_name != null or self.email != null or
                self.subject != null or self.login != null or self.password_hash != null;
        }

        pub fn validate(self: Bootstrap) ConfigError!void {
            if (!self.isConfigured()) return;
            const display_name = self.display_name orelse return error.InvalidAuthConfiguration;
            auth_identity.validateDisplayName(display_name) catch return error.InvalidAuthConfiguration;
            if (self.email) |email| {
                auth_identity.validateEmail(email) catch return error.InvalidAuthConfiguration;
            }
            if (self.subject) |subject| {
                auth_identity.validateBootstrapOwner(.{
                    .subject = subject,
                    .display_name = display_name,
                    .email = self.email,
                }) catch return error.InvalidAuthConfiguration;
            }

            if ((self.login == null) != (self.password_hash == null)) {
                return error.InvalidAuthConfiguration;
            }
            if (self.login) |login| {
                auth_password.validateLogin(login) catch return error.InvalidAuthConfiguration;
            }
            if (self.password_hash) |password_hash| {
                auth_password.validateEncodedHash(password_hash) catch return error.InvalidAuthConfiguration;
            } else {
                // Email-only bootstrap is reserved for the future OIDC provider
                // configuration and must not silently create a local account.
                return error.InvalidAuthConfiguration;
            }
        }
    };

    pub const Migrations = struct {
        path: []const u8 = "migrations",
        run_on_startup: bool = true,
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

    pub const Mcp = struct {
        enabled: bool = true,
        allow_publish: bool = false,
    };

    pub fn parse(allocator: std.mem.Allocator, toml_source: []const u8) !toml.Parsed(Config) {
        var parser = toml.Parser(Config).init(allocator);
        defer parser.deinit();

        var parsed_config = try parser.parseString(toml_source);
        errdefer parsed_config.deinit();
        return parsed_config;
    }

    pub fn writeDefault(writer: *std.Io.Writer) !void {
        try defaults.write(writer);
    }

    pub fn validate(self: Config) (ConfigError || std.mem.Allocator.Error)!void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        return self.validateWithAllocator(arena.allocator());
    }

    pub fn validateWithAllocator(self: Config, allocator: std.mem.Allocator) (ConfigError || std.mem.Allocator.Error)!void {
        if (!validation.isSafeText(self.site.name)) return error.InvalidSiteName;
        if (!validation.isValidServerHost(self.server.host)) return error.InvalidServerHost;
        if (self.server.port == 0) return error.InvalidServerHost;
        if (self.security.trusted_proxy_addresses.len != 0 and
            !validation.isSafeText(self.security.trusted_proxy_addresses))
        {
            return error.InvalidSecurityConfiguration;
        }
        var proxy_addresses = std.mem.splitScalar(u8, self.security.trusted_proxy_addresses, ',');
        while (proxy_addresses.next()) |address| {
            if (self.security.trusted_proxy_addresses.len != 0 and
                (address.len == 0 or !validation.isSafeToken(address)))
            {
                return error.InvalidSecurityConfiguration;
            }
        }

        if (self.site.base_url) |base_url| {
            if (!validation.isValidBaseUrl(base_url)) return error.InvalidBaseUrl;
            if (self.runtime.environment == .production and
                try validation.isLoopbackBaseUrlWithAllocator(allocator, base_url))
            {
                return error.InvalidBaseUrl;
            }
        } else if (self.runtime.environment == .production or
            !validation.isLoopbackHost(self.server.host))
        {
            return error.MissingBaseUrl;
        }

        if (!(try validation.isValidDatabaseUrlWithAllocator(allocator, self.database.url))) {
            return error.InvalidDatabaseUrl;
        }
        if (!validation.isValidPath(self.migrations.path)) return error.InvalidMigrationConfiguration;

        switch (self.storage) {
            .filesystem => |filesystem| {
                if (!validation.isValidPath(filesystem.path)) return error.InvalidStoragePath;
            },
        }
        if (!validation.isValidPath(self.cache.path)) return error.InvalidCachePath;
        if (self.public_static_root) |root| {
            if (!validation.isValidPath(root)) return error.InvalidPublicStaticPath;
        }

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

        if (self.mcp.allow_publish and !self.mcp.enabled) {
            return error.InvalidMcpConfiguration;
        }
        if (self.features.interactive_sections) {
            return error.InvalidFeatureConfiguration;
        }
        try self.auth.bootstrap.validate();
    }

    pub fn effectiveLoggingFormat(self: Config, stderr_is_tty: bool) logging.ResolvedFormat {
        return switch (self.logging.format) {
            .auto => if (self.runtime.environment == .production)
                .json
            else if (stderr_is_tty)
                .pretty
            else
                .text,
            .json => .json,
            .text => .text,
            .pretty => .pretty,
        };
    }

    pub fn effectiveBaseUrl(self: Config, allocator: std.mem.Allocator) ![]u8 {
        if (self.site.base_url) |base_url| return allocator.dupe(u8, base_url);
        if (std.mem.indexOfScalar(u8, self.server.host, ':') != null) {
            return std.fmt.allocPrint(allocator, "http://[{s}]:{}", .{ self.server.host, self.server.port });
        }
        return std.fmt.allocPrint(allocator, "http://{s}:{}", .{ self.server.host, self.server.port });
    }

    pub fn uiLanguageTag(self: Config) []const u8 {
        return @tagName(self.ui.language);
    }
};
