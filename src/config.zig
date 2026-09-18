const defaults = @import("config/defaults.zig");
const loading = @import("config/load.zig");
const types = @import("config/types.zig");

pub const Config = types.Config;
pub const ConfigError = types.ConfigError;
pub const Environment = types.Environment;
pub const UiLanguage = types.UiLanguage;
pub const LoggingFormat = types.LoggingFormat;
pub const ResolvedLoggingFormat = types.ResolvedLoggingFormat;
pub const ConfigSources = loading.ConfigSources;
pub const CliOverrides = loading.CliOverrides;

pub const load = loading.load;
pub const loadFile = loading.loadFile;
pub const writeDefault = defaults.write;

comptime {
    _ = @import("config/tests.zig");
}
