const std = @import("std");
const loading = @import("load.zig");
const types = @import("types.zig");

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

    var parsed = try types.Config.parse(std.testing.allocator, input);
    defer parsed.deinit();
    try parsed.value.validate();

    try std.testing.expectEqualStrings("Example Publication", parsed.value.site.name);
    try std.testing.expectEqual(types.Environment.production, parsed.value.runtime.environment);
    try std.testing.expectEqual(types.LoggingFormat.auto, parsed.value.logging.format);
    try std.testing.expectEqual(types.UiLanguage.en, parsed.value.ui.language);
    try std.testing.expectEqualStrings("en", parsed.value.uiLanguageTag());
    try std.testing.expectEqual(@as(u16, 9090), parsed.value.server.port);
    try std.testing.expectEqualStrings("./schema", parsed.value.migrations.path);
    try std.testing.expectEqual(false, parsed.value.migrations.run_on_startup);
    try std.testing.expectEqual(@as(u32, 500), parsed.value.editor.local_preview_debounce_ms);
    switch (parsed.value.storage) {
        .filesystem => |filesystem| try std.testing.expectEqualStrings("./data/assets", filesystem.path),
    }
}

test "default configuration output is valid TOML" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try types.Config.writeDefault(&writer);

    var parsed = try types.Config.parse(std.testing.allocator, writer.buffered());
    defer parsed.deinit();
    try parsed.value.validate();
    try std.testing.expectEqual(types.Environment.development, parsed.value.runtime.environment);
    try std.testing.expectEqualStrings("Verso", parsed.value.site.name);
    try std.testing.expectEqual(types.LoggingFormat.auto, parsed.value.logging.format);
    try std.testing.expectEqual(true, parsed.value.logging.omit_null_fields);
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
    var parsed = try types.Config.parse(std.testing.allocator, "[logging]\nformat = 'pretty'\n");
    defer parsed.deinit();
    try parsed.value.validate();
    try std.testing.expectEqual(
        types.ResolvedLoggingFormat.pretty,
        parsed.value.effectiveLoggingFormat(false),
    );
}

test "development derives a loopback base URL" {
    var parsed = try types.Config.parse(std.testing.allocator, "");
    defer parsed.deinit();
    try parsed.value.validate();

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", try parsed.value.effectiveBaseUrl(&buffer));
}

test "development brackets expanded IPv6 loopback URLs" {
    var parsed = try types.Config.parse(
        std.testing.allocator,
        "[server]\nhost = '0:0:0:0:0:0:0:1'\nport = 9090\n",
    );
    defer parsed.deinit();
    try parsed.value.validate();

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://[0:0:0:0:0:0:0:1]:9090",
        try parsed.value.effectiveBaseUrl(&buffer),
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

test "unsupported UI logo variants are rejected after parsing" {
    var parsed = try types.Config.parse(std.testing.allocator, "[ui]\nicon = '/assets/icon.svg'\n");
    defer parsed.deinit();
    try std.testing.expectError(error.UnsupportedLogoVariant, parsed.value.validate());
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
    var parsed = try loading.loadFile(std.testing.io, std.testing.allocator, "testdata/verso.toml", .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Example Publication", parsed.value.site.name);
    try std.testing.expectEqual(types.UiLanguage.en, parsed.value.ui.language);
    switch (parsed.value.storage) {
        .filesystem => |filesystem| try std.testing.expectEqualStrings("./data/assets", filesystem.path),
    }
}

test "optional configuration falls back to built-in defaults" {
    var parsed = try loading.loadFile(std.testing.io, std.testing.allocator, "testdata/missing-verso.toml", .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Verso", parsed.value.site.name);
    try std.testing.expectEqual(@as(u16, 8080), parsed.value.server.port);
    try std.testing.expectEqualStrings("./data/verso.db", parsed.value.database.url);
    try std.testing.expectEqualStrings("migrations", parsed.value.migrations.path);
    try std.testing.expectEqual(true, parsed.value.migrations.run_on_startup);
}

test "environment overrides take precedence over TOML" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("VERSO_SITE_NAME", "Environment Publication");
    try environ.put("VERSO_SITE_BASE_URL", "https://environment.example");
    try environ.put("VERSO_SERVER_PORT", "9090");
    try environ.put("VERSO_DATABASE_URL", "./data/environment.db");
    try environ.put("VERSO_STORAGE_FS_PATH", "./data/environment-assets");
    try environ.put("VERSO_LOGGING_OMIT_NULL_FIELDS", "false");
    try environ.put("VERSO_FEATURES_MATH", "false");
    try environ.put("VERSO_EDITOR_LOCAL_PREVIEW_DEBOUNCE_MS", "750");

    var parsed = try loading.loadFile(std.testing.io, std.testing.allocator, "testdata/verso.toml", .{ .envs = &environ });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Environment Publication", parsed.value.site.name);
    try std.testing.expectEqualStrings("https://environment.example", parsed.value.site.base_url.?);
    try std.testing.expectEqual(@as(u16, 9090), parsed.value.server.port);
    try std.testing.expectEqual(false, parsed.value.logging.omit_null_fields);
    try std.testing.expectEqualStrings("./data/environment.db", parsed.value.database.url);
    try std.testing.expectEqual(false, parsed.value.features.math);
    try std.testing.expectEqual(@as(u32, 750), parsed.value.editor.local_preview_debounce_ms);
    switch (parsed.value.storage) {
        .filesystem => |filesystem| try std.testing.expectEqualStrings("./data/environment-assets", filesystem.path),
    }
}

test "environment overrides are applied before validation" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("VERSO_RUNTIME_ENVIRONMENT", "production");
    try environ.put("VERSO_LOGGING_FORMAT", "text");
    try environ.put("VERSO_SITE_BASE_URL", "https://environment.example");

    var parsed = try loading.load(std.testing.allocator, .{
        .toml = "[runtime]\nenvironment = 'production'\n[logging]\nformat = 'pretty'\n",
        .envs = &environ,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(types.Environment.production, parsed.value.runtime.environment);
    try std.testing.expectEqual(types.LoggingFormat.text, parsed.value.logging.format);
    try std.testing.expectEqualStrings("https://environment.example", parsed.value.site.base_url.?);
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

test "unknown environment variables do not change configuration" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("VERSO_UNKNOWN_SETTING", "unexpected");

    var parsed = try loading.load(std.testing.allocator, .{ .envs = &environ });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Verso", parsed.value.site.name);
}
