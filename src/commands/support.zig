const std = @import("std");
const verso = @import("verso");
const logging = verso.logging;

pub fn logCommandFailure(
    init: std.process.Init,
    command_name: []const u8,
    stage: []const u8,
    level: []const u8,
    failure: anyerror,
) void {
    const stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false;
    var logger = logging.Logger.initWithOptions(
        init.gpa,
        if (stderr_is_tty) .pretty else .text,
        .{ .use_color = stderr_is_tty, .omit_null_fields = true },
    );
    logger.log(init.io, .{
        .level = level,
        .event = "command.failed",
        .message = "command failed",
        .command = command_name,
        .stage = stage,
        .error_name = @errorName(failure),
        .reason = verso.failure_reason.forError(failure),
        .suggestion = verso.failure_reason.suggestion(failure),
    }) catch {};
}

pub fn logConfigurationFailure(
    init: std.process.Init,
    command_name: []const u8,
    configuration_error: anyerror,
) void {
    const stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false;
    var logger = logging.Logger.initWithOptions(
        init.gpa,
        if (stderr_is_tty) .pretty else .text,
        .{ .use_color = stderr_is_tty, .omit_null_fields = true },
    );
    logger.log(init.io, .{
        .level = "error",
        .event = "configuration.failed",
        .message = "configuration failed",
        .command = command_name,
        .error_name = @errorName(configuration_error),
        .reason = verso.failure_reason.forError(configuration_error),
        .suggestion = verso.failure_reason.suggestion(configuration_error),
    }) catch {};
}

pub fn logValidationFailure(
    init: std.process.Init,
    command_name: []const u8,
    validation_error: anyerror,
) void {
    if (!verso.failure_reason.isValidationError(validation_error)) return;
    const stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false;
    var logger = logging.Logger.initWithOptions(
        init.gpa,
        if (stderr_is_tty) .pretty else .text,
        .{ .use_color = stderr_is_tty, .omit_null_fields = true },
    );
    logger.log(init.io, .{
        .level = "warn",
        .event = "validation.failed",
        .message = "input validation failed",
        .command = command_name,
        .error_name = @errorName(validation_error),
        .reason = verso.failure_reason.forError(validation_error),
        .suggestion = verso.failure_reason.suggestion(validation_error),
    }) catch {};
}

pub fn logConfigurationLoaded(
    init: std.process.Init,
    command_name: []const u8,
    app_config: verso.config.Config,
    cli_overrides: verso.config.CliOverrides,
) void {
    const stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false;
    var logger = logging.Logger.initWithOptions(
        init.gpa,
        app_config.effectiveLoggingFormat(stderr_is_tty),
        .{
            .use_color = stderr_is_tty,
            .omit_null_fields = app_config.logging.omit_null_fields,
        },
    );
    logger.log(init.io, .{
        .level = "debug",
        .event = "configuration.loaded",
        .message = "configuration loaded",
        .command = command_name,
        .config_file = cli_overrides.config_path orelse "verso.toml",
    }) catch {};
}
