const std = @import("std");
const loading = @import("load.zig");
const types = @import("types.zig");

test "parses and validates a complete configuration" {
    const toml_source =
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
        \\[migrations]
        \\path = './schema'
        \\run_on_startup = false
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

    var parsed_config = try types.Config.parse(std.testing.allocator, toml_source);
    defer parsed_config.deinit();
    try parsed_config.value.validate();

    try std.testing.expectEqualStrings("Example Publication", parsed_config.value.site.name);
    try std.testing.expectEqual(types.Environment.production, parsed_config.value.runtime.environment);
    try std.testing.expectEqual(types.LoggingFormat.auto, parsed_config.value.logging.format);
    try std.testing.expectEqual(types.UiLanguage.en, parsed_config.value.ui.language);
    try std.testing.expectEqualStrings("en", parsed_config.value.uiLanguageTag());
    try std.testing.expectEqual(@as(u16, 9090), parsed_config.value.server.port);
    try std.testing.expectEqualStrings("./schema", parsed_config.value.migrations.path);
    try std.testing.expectEqual(false, parsed_config.value.migrations.run_on_startup);
    try std.testing.expectEqual(@as(u32, 500), parsed_config.value.editor.local_preview_debounce_ms);
    switch (parsed_config.value.storage) {
        .filesystem => |filesystem| try std.testing.expectEqualStrings("./data/assets", filesystem.path),
    }
}

test "default configuration output is valid TOML" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try types.Config.writeDefault(&writer);

    var parsed_config = try types.Config.parse(std.testing.allocator, writer.buffered());
    defer parsed_config.deinit();
    try parsed_config.value.validate();
    try std.testing.expectEqual(types.Environment.development, parsed_config.value.runtime.environment);
    try std.testing.expectEqualStrings("Verso", parsed_config.value.site.name);
    try std.testing.expectEqual(types.LoggingFormat.auto, parsed_config.value.logging.format);
    try std.testing.expectEqual(true, parsed_config.value.logging.omit_null_fields);
}

test "public static root is separate from canonical storage paths" {
    var app_config = types.Config{ .public_static_root = "./public" };
    try app_config.validate();
    try std.testing.expectEqualStrings("./public", app_config.public_static_root.?);

    app_config.public_static_root = "./public/../secrets";
    try std.testing.expectError(error.InvalidPublicStaticPath, app_config.validate());
}

test "logging format defaults follow environment and stderr" {
    var development = try types.Config.parse(std.testing.allocator, "");
    defer development.deinit();
    try std.testing.expectEqual(
        types.ResolvedLoggingFormat.pretty,
        development.value.effectiveLoggingFormat(true),
    );
    try std.testing.expectEqual(
        types.ResolvedLoggingFormat.text,
        development.value.effectiveLoggingFormat(false),
    );

    var production = try types.Config.parse(std.testing.allocator, "[runtime]\nenvironment = 'production'\n");
    defer production.deinit();
    try std.testing.expectEqual(
        types.ResolvedLoggingFormat.json,
        production.value.effectiveLoggingFormat(true),
    );
    try std.testing.expectEqual(
        types.ResolvedLoggingFormat.json,
        production.value.effectiveLoggingFormat(false),
    );
}

test "explicit logging format overrides automatic defaults" {
    var parsed_config = try types.Config.parse(std.testing.allocator, "[logging]\nformat = 'pretty'\n");
    defer parsed_config.deinit();
    try parsed_config.value.validate();
    try std.testing.expectEqual(
        types.ResolvedLoggingFormat.pretty,
        parsed_config.value.effectiveLoggingFormat(false),
    );
}

test "development derives a loopback base URL" {
    var parsed_config = try types.Config.parse(std.testing.allocator, "");
    defer parsed_config.deinit();
    try parsed_config.value.validate();

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", try parsed_config.value.effectiveBaseUrl(&buffer));
}

test "development brackets expanded IPv6 loopback URLs" {
    var parsed_config = try types.Config.parse(
        std.testing.allocator,
        "[server]\nhost = '0:0:0:0:0:0:0:1'\nport = 9090\n",
    );
    defer parsed_config.deinit();
    try parsed_config.value.validate();

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://[0:0:0:0:0:0:0:1]:9090",
        try parsed_config.value.effectiveBaseUrl(&buffer),
    );
}

test "production requires an explicit public base URL" {
    var missing = try types.Config.parse(std.testing.allocator, "[runtime]\nenvironment = 'production'\n");
    defer missing.deinit();
    try std.testing.expectError(error.MissingBaseUrl, missing.value.validate());

    var loopback = try types.Config.parse(
        std.testing.allocator,
        "[runtime]\nenvironment = 'production'\n[site]\nbase_url = 'http://127.0.0.1:8080'\n",
    );
    defer loopback.deinit();
    try std.testing.expectError(error.InvalidBaseUrl, loopback.value.validate());
}

test "security configuration requires explicit proxy address tokens" {
    var parsed_config = try types.Config.parse(
        std.testing.allocator,
        "[security]\ntrusted_proxy_addresses = '192.0.2.10,192.0.2.11'\n",
    );
    defer parsed_config.deinit();
    try parsed_config.value.validate();
    try std.testing.expectEqualStrings(
        "192.0.2.10,192.0.2.11",
        parsed_config.value.security.trusted_proxy_addresses,
    );

    var invalid = try types.Config.parse(
        std.testing.allocator,
        "[security]\ntrusted_proxy_addresses = '192.0.2.10, 192.0.2.11'\n",
    );
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidSecurityConfiguration, invalid.value.validate());
}

test "unsupported UI logo variants are rejected after parsing" {
    var parsed_config = try types.Config.parse(std.testing.allocator, "[ui]\nicon = '/assets/icon.svg'\n");
    defer parsed_config.deinit();
    try std.testing.expectError(error.UnsupportedLogoVariant, parsed_config.value.validate());
}

test "unsupported UI languages are rejected by TOML enum mapping" {
    try std.testing.expectError(
        error.InvalidValueType,
        types.Config.parse(std.testing.allocator, "[ui]\nlanguage = 'xx'\n"),
    );
}

test "unsafe configuration is rejected" {
    var interactive = try types.Config.parse(std.testing.allocator, "[features]\ninteractive_sections = true\n");
    defer interactive.deinit();
    try std.testing.expectError(error.InvalidFeatureConfiguration, interactive.value.validate());

    var traversal = try types.Config.parse(std.testing.allocator, "[database]\nurl = './data/../secrets.db'\n");
    defer traversal.deinit();
    try std.testing.expectError(error.InvalidDatabaseUrl, traversal.value.validate());

    var migration_traversal = try types.Config.parse(
        std.testing.allocator,
        "[migrations]\npath = './data/../migrations'\n",
    );
    defer migration_traversal.deinit();
    try std.testing.expectError(error.InvalidMigrationConfiguration, migration_traversal.value.validate());
}

test "loads a configuration file" {
    var parsed_config = try loading.loadFile(std.testing.io, std.testing.allocator, "testdata/verso.toml", .{});
    defer parsed_config.deinit();

    try std.testing.expectEqualStrings("Example Publication", parsed_config.value.site.name);
    try std.testing.expectEqual(types.UiLanguage.en, parsed_config.value.ui.language);
    switch (parsed_config.value.storage) {
        .filesystem => |filesystem| try std.testing.expectEqualStrings("./data/assets", filesystem.path),
    }
}

test "optional configuration falls back to built-in defaults" {
    var parsed_config = try loading.loadFile(std.testing.io, std.testing.allocator, "testdata/missing-verso.toml", .{});
    defer parsed_config.deinit();

    try std.testing.expectEqualStrings("Verso", parsed_config.value.site.name);
    try std.testing.expectEqual(@as(u16, 8080), parsed_config.value.server.port);
    try std.testing.expectEqualStrings("./data/verso.db", parsed_config.value.database.url);
    try std.testing.expectEqualStrings("migrations", parsed_config.value.migrations.path);
    try std.testing.expectEqual(true, parsed_config.value.migrations.run_on_startup);
}

test "environment overrides take precedence over TOML" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("VERSO_SITE_NAME", "Environment Publication");
    try environ.put("VERSO_SITE_BASE_URL", "https://environment.example");
    try environ.put("VERSO_SERVER_PORT", "9090");
    try environ.put("VERSO_DATABASE_URL", "./data/environment.db");
    try environ.put("VERSO_STORAGE_FS_PATH", "./data/environment-assets");
    try environ.put("VERSO_MIGRATIONS_PATH", "./data/environment-migrations");
    try environ.put("VERSO_MIGRATIONS_RUN_ON_STARTUP", "false");
    try environ.put("VERSO_LOGGING_OMIT_NULL_FIELDS", "false");
    try environ.put("VERSO_FEATURES_MATH", "false");
    try environ.put("VERSO_EDITOR_LOCAL_PREVIEW_DEBOUNCE_MS", "750");

    var parsed_config = try loading.loadFile(std.testing.io, std.testing.allocator, "testdata/verso.toml", .{ .envs = &environ });
    defer parsed_config.deinit();

    try std.testing.expectEqualStrings("Environment Publication", parsed_config.value.site.name);
    try std.testing.expectEqualStrings("https://environment.example", parsed_config.value.site.base_url.?);
    try std.testing.expectEqual(@as(u16, 9090), parsed_config.value.server.port);
    try std.testing.expectEqual(false, parsed_config.value.logging.omit_null_fields);
    try std.testing.expectEqualStrings("./data/environment.db", parsed_config.value.database.url);
    try std.testing.expectEqualStrings("./data/environment-migrations", parsed_config.value.migrations.path);
    try std.testing.expectEqual(false, parsed_config.value.migrations.run_on_startup);
    try std.testing.expectEqual(false, parsed_config.value.features.math);
    try std.testing.expectEqual(@as(u32, 750), parsed_config.value.editor.local_preview_debounce_ms);
    switch (parsed_config.value.storage) {
        .filesystem => |filesystem| try std.testing.expectEqualStrings("./data/environment-assets", filesystem.path),
    }
}

test "environment overrides are applied before validation" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("VERSO_RUNTIME_ENVIRONMENT", "production");
    try environ.put("VERSO_LOGGING_FORMAT", "text");
    try environ.put("VERSO_SITE_BASE_URL", "https://environment.example");

    var parsed_config = try loading.load(std.testing.allocator, .{
        .toml = "[runtime]\nenvironment = 'production'\n[logging]\nformat = 'pretty'\n",
        .envs = &environ,
    });
    defer parsed_config.deinit();

    try std.testing.expectEqual(types.Environment.production, parsed_config.value.runtime.environment);
    try std.testing.expectEqual(types.LoggingFormat.text, parsed_config.value.logging.format);
    try std.testing.expectEqualStrings("https://environment.example", parsed_config.value.site.base_url.?);
}

test "environment overrides reject invalid typed values" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("VERSO_SERVER_PORT", "not-a-port");

    try std.testing.expectError(
        error.InvalidEnvironmentValue,
        loading.load(std.testing.allocator, .{ .envs = &environ }),
    );
}

test "command-line overrides take precedence over environment and TOML" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("VERSO_SITE_NAME", "Environment Publication");
    try environ.put("VERSO_SERVER_PORT", "9090");
    try environ.put("VERSO_DATABASE_URL", "./data/environment.db");

    var parsed_config = try loading.load(std.testing.allocator, .{
        .toml = "[site]\nname = 'TOML Publication'\nbase_url = 'https://toml.example'\n[server]\nport = 8081\n[database]\nurl = './data/toml.db'\n",
        .envs = &environ,
        .cli = .{
            .site_name = "CLI Publication",
            .server_port = 7070,
            .database_url = "./data/cli.db",
        },
    });
    defer parsed_config.deinit();

    try std.testing.expectEqualStrings("CLI Publication", parsed_config.value.site.name);
    try std.testing.expectEqual(@as(u16, 7070), parsed_config.value.server.port);
    try std.testing.expectEqualStrings("./data/cli.db", parsed_config.value.database.url);
}

test "an explicitly selected configuration file is required" {
    try std.testing.expectError(
        error.FileNotFound,
        loading.loadFile(std.testing.io, std.testing.allocator, "verso.toml", .{
            .cli = .{ .config_path = "testdata/missing-selected-verso.toml" },
        }),
    );
}

test "an alternate configuration file path is loaded before overrides" {
    var parsed_config = try loading.loadFile(std.testing.io, std.testing.allocator, "verso.toml", .{
        .cli = .{
            .config_path = "testdata/verso.toml",
            .site_name = "CLI Publication",
        },
    });
    defer parsed_config.deinit();

    try std.testing.expectEqualStrings("CLI Publication", parsed_config.value.site.name);
    try std.testing.expectEqual(@as(u16, 9090), parsed_config.value.server.port);
}

test "unknown environment variables do not change configuration" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("VERSO_UNKNOWN_SETTING", "unexpected");

    var parsed_config = try loading.load(std.testing.allocator, .{ .envs = &environ });
    defer parsed_config.deinit();
    try std.testing.expectEqualStrings("Verso", parsed_config.value.site.name);
}
