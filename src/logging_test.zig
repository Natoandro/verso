const std = @import("std");
const writeRecord = @import("logging.zig").writeRecord;
const DurationMilliseconds = @import("web/logging.zig").DurationMilliseconds;

test "generic records are JSON lines with logger-owned timestamps" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeRecord(&writer, std.testing.allocator, .json, 1_735_689_600_000, false, false, .{
        .level = "info",
        .event = "http.request",
        .method = "GET",
        .target = "/notes/hello?draft=true",
        .status = 200,
        .duration_ms = DurationMilliseconds{ .milliseconds = 3.25 },
        .error_name = null,
    });

    try std.testing.expectEqualStrings(
        "{\"timestamp\":\"2025-01-01T00:00:00.000Z\",\"level\":\"info\",\"event\":\"http.request\",\"method\":\"GET\",\"target\":\"/notes/hello?draft=true\",\"status\":200,\"duration_ms\":3.25,\"error_name\":null}\n",
        writer.buffered(),
    );
}

test "generic records preserve message in text and use it as the pretty headline" {
    var text_buffer: [1024]u8 = undefined;
    var text_writer = std.Io.Writer.fixed(&text_buffer);
    const record = .{
        .level = @as([]const u8, "info"),
        .event = @as([]const u8, "http.request"),
        .message = @as([]const u8, "request completed"),
        .method = @as([]const u8, "GET"),
        .target = @as([]const u8, "/notes/hello"),
        .status = @as(?u16, 200),
        .duration_ms = DurationMilliseconds{ .milliseconds = 3.25 },
        .error_name = @as(?[]const u8, null),
    };

    try writeRecord(&text_writer, std.testing.allocator, .text, 1_735_689_600_000, false, false, record);
    try std.testing.expectEqualStrings(
        "timestamp=\"2025-01-01T00:00:00.000Z\" level=\"info\" event=\"http.request\" message=\"request completed\" method=\"GET\" target=\"/notes/hello\" status=200 duration_ms=3.25 error_name=null\n",
        text_writer.buffered(),
    );

    var pretty_buffer: [1024]u8 = undefined;
    var pretty_writer = std.Io.Writer.fixed(&pretty_buffer);
    try writeRecord(&pretty_writer, std.testing.allocator, .pretty, 1_735_689_600_000, false, false, record);
    try std.testing.expectEqualStrings(
        "[2025-01-01T00:00:00.000Z] INFO request completed method=\"GET\" target=\"/notes/hello\" status=200 duration_ms=3.25 error_name=null\n",
        pretty_writer.buffered(),
    );
}

test "duration display switches to seconds for long requests" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try (DurationMilliseconds{ .milliseconds = 1_234_567 }).logFormat(&writer);
    try std.testing.expectEqualStrings(
        "1.23457e3s",
        writer.buffered(),
    );
}

test "pretty formatting accepts a non-request record" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeRecord(&writer, std.testing.allocator, .pretty, 42, false, false, .{
        .level = "info",
        .event = "startup",
        .component = @as([]const u8, "runtime"),
        .message = @as([]const u8, "ready"),
    });

    try std.testing.expectEqualStrings(
        "[1970-01-01T00:00:00.042Z] INFO ready component=\"runtime\"\n",
        writer.buffered(),
    );
}

test "pretty formatting renders debug level consistently" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeRecord(&writer, std.testing.allocator, .pretty, 42, false, false, .{
        .level = "debug",
        .event = "startup",
        .message = @as([]const u8, "diagnostic detail"),
    });

    try std.testing.expectEqualStrings(
        "[1970-01-01T00:00:00.042Z] DEBUG diagnostic detail\n",
        writer.buffered(),
    );
}

test "pretty formatting mutes colored debug levels" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeRecord(&writer, std.testing.allocator, .pretty, 42, true, false, .{
        .level = "debug",
        .event = "startup",
        .message = @as([]const u8, "diagnostic detail"),
    });

    try std.testing.expectEqualStrings(
        "\x1b[2m[1970-01-01T00:00:00.042Z]\x1b[0m \x1b[2mDEBUG\x1b[0m \x1b[36m\x1b[1mdiagnostic detail\x1b[0m\n",
        writer.buffered(),
    );
}

test "pretty formatting colors the timestamp, level, message, and fields" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeRecord(&writer, std.testing.allocator, .pretty, 42, true, false, .{
        .level = "error",
        .event = "startup.failed",
        .message = @as([]const u8, "unavailable"),
    });

    try std.testing.expectEqualStrings(
        "\x1b[2m[1970-01-01T00:00:00.042Z]\x1b[0m \x1b[31m\x1b[1mERROR\x1b[0m \x1b[36m\x1b[1munavailable\x1b[0m\n",
        writer.buffered(),
    );
}

test "pretty formatting escapes control characters in headers" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeRecord(&writer, std.testing.allocator, .pretty, 42, false, false, .{
        .level = @as([]const u8, "notice\n"),
        .event = @as([]const u8, "startup\x1b[31m"),
    });

    try std.testing.expectEqualStrings(
        "[1970-01-01T00:00:00.042Z] notice\\x0a startup\\x1b[31m\n",
        writer.buffered(),
    );
}

test "null fields can be omitted from every format" {
    const record = .{
        .level = @as([]const u8, "info"),
        .event = @as([]const u8, "http.request"),
        .status = @as(?u16, null),
        .error_name = @as(?[]const u8, null),
        .duration_ms = DurationMilliseconds{ .milliseconds = 3.25 },
    };

    var json_buffer: [1024]u8 = undefined;
    var json_writer = std.Io.Writer.fixed(&json_buffer);
    try writeRecord(&json_writer, std.testing.allocator, .json, 42, false, true, record);
    try std.testing.expectEqualStrings(
        "{\"timestamp\":\"1970-01-01T00:00:00.042Z\",\"level\":\"info\",\"event\":\"http.request\",\"duration_ms\":3.25}\n",
        json_writer.buffered(),
    );

    var text_buffer: [1024]u8 = undefined;
    var text_writer = std.Io.Writer.fixed(&text_buffer);
    try writeRecord(&text_writer, std.testing.allocator, .text, 42, false, true, record);
    try std.testing.expectEqualStrings(
        "timestamp=\"1970-01-01T00:00:00.042Z\" level=\"info\" event=\"http.request\" duration_ms=3.25\n",
        text_writer.buffered(),
    );

    var pretty_buffer: [1024]u8 = undefined;
    var pretty_writer = std.Io.Writer.fixed(&pretty_buffer);
    try writeRecord(&pretty_writer, std.testing.allocator, .pretty, 42, false, true, record);
    try std.testing.expectEqualStrings(
        "[1970-01-01T00:00:00.042Z] INFO http.request duration_ms=3.25\n",
        pretty_writer.buffered(),
    );
}

test "comptime record format builds the text and pretty message without serializing format" {
    const Record = struct {
        comptime format: []const u8 = "HTTP {method} completed with {status}",
        level: []const u8,
        event: []const u8,
        method: []const u8,
        status: u16,
        component: []const u8,
    };
    const record: Record = .{
        .level = "info",
        .event = "http.request",
        .method = "GET",
        .status = 200,
        .component = "web",
    };

    var json_buffer: [1024]u8 = undefined;
    var json_writer = std.Io.Writer.fixed(&json_buffer);
    try writeRecord(&json_writer, std.testing.allocator, .json, 42, false, false, record);
    try std.testing.expectEqualStrings(
        "{\"timestamp\":\"1970-01-01T00:00:00.042Z\",\"level\":\"info\",\"event\":\"http.request\",\"method\":\"GET\",\"status\":200,\"component\":\"web\"}\n",
        json_writer.buffered(),
    );

    var text_buffer: [1024]u8 = undefined;
    var text_writer = std.Io.Writer.fixed(&text_buffer);
    try writeRecord(&text_writer, std.testing.allocator, .text, 42, false, false, record);
    try std.testing.expectEqualStrings(
        "timestamp=\"1970-01-01T00:00:00.042Z\" message=\"HTTP GET completed with 200\" level=\"info\" event=\"http.request\" component=\"web\"\n",
        text_writer.buffered(),
    );

    var pretty_buffer: [1024]u8 = undefined;
    var pretty_writer = std.Io.Writer.fixed(&pretty_buffer);
    try writeRecord(&pretty_writer, std.testing.allocator, .pretty, 42, false, false, record);
    try std.testing.expectEqualStrings(
        "[1970-01-01T00:00:00.042Z] INFO HTTP GET completed with 200 component=\"web\"\n",
        pretty_writer.buffered(),
    );
}
