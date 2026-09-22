const defaults = @import("config/defaults.zig");
const loading = @import("config/load.zig");
const schema = @import("config/schema.zig");
const types = @import("config/types.zig");
const toml = @import("toml");

pub const Config = types.Config;
pub const Parsed = toml.Parsed(Config);
pub const ConfigError = types.ConfigError;
pub const Environment = types.Environment;
pub const UiLanguage = types.UiLanguage;
pub const LoggingFormat = types.LoggingFormat;
pub const ResolvedLoggingFormat = types.ResolvedLoggingFormat;
pub const ConfigSources = loading.ConfigSources;
pub const CliOverrides = loading.CliOverrides;
pub const CliMetadata = schema.CliMetadata;
pub const serve_cli_metadata = schema.serve_cli_metadata;
pub const environment_fields = schema.environment_fields;
pub const environment_reference = schema.environment_reference;

pub const load = loading.load;
pub const loadFile = loading.loadFile;
pub const writeDefault = defaults.write;
pub const fieldType = schema.fieldType;
pub const cliName = schema.cliName;
pub const cliOptionName = schema.cliOptionName;
pub const cliPlaceholderName = schema.cliPlaceholderName;
pub const environmentName = schema.environmentName;

comptime {
    _ = @import("config/tests.zig");
}
