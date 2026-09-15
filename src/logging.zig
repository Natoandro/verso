const std = @import("std");

pub const Format = enum {
    auto,
    json,
    text,
    pretty,
};

pub const ResolvedFormat = enum {
    json,
    text,
    pretty,
};

pub const Options = struct {
    use_color: bool = false,
    omit_null_fields: bool = false,
};

const ansi = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const bold = "\x1b[1m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const cyan = "\x1b[36m";
};

pub const Logger = struct {
    allocator: std.mem.Allocator,
    format: ResolvedFormat,
    use_color: bool,
    omit_null_fields: bool,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, format: ResolvedFormat) Logger {
        return initWithOptions(allocator, format, .{ .use_color = format == .pretty });
    }

    pub fn initWithColor(
        allocator: std.mem.Allocator,
        format: ResolvedFormat,
        use_color: bool,
    ) Logger {
        return initWithOptions(allocator, format, .{ .use_color = use_color });
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        format: ResolvedFormat,
        options: Options,
    ) Logger {
        return .{
            .allocator = allocator,
            .format = format,
            .use_color = options.use_color and format == .pretty,
            .omit_null_fields = options.omit_null_fields,
        };
    }

    /// Writes one structured log record. The record may be any struct; the
    /// logger adds the wall-clock timestamp to the serialized output.
    ///
    /// `timestamp` and `timestamp_ms` are reserved for the logger and must
    /// not be fields in the supplied record. `level` and `event` are
    /// conventional fields used by the pretty formatter when present, but are
    /// not otherwise required.
    pub fn log(self: *Logger, io: std.Io, record: anytype) !void {
        const timestamp_ms = std.Io.Clock.now(.real, io).toMilliseconds();

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        var output = std.Io.Writer.Allocating.init(self.allocator);
        defer output.deinit();
        try writeRecord(
            &output.writer,
            self.format,
            timestamp_ms,
            self.use_color,
            self.omit_null_fields,
            record,
        );

        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &buffer);
        try writer.interface.writeAll(output.written());
        try writer.flush();
    }
};

fn writeRecord(
    writer: *std.Io.Writer,
    format: ResolvedFormat,
    timestamp_ms: i64,
    use_color: bool,
    omit_null_fields: bool,
    record: anytype,
) !void {
    ensureRecordType(@TypeOf(record));

    switch (format) {
        .json => try writeJsonRecordBody(writer, timestamp_ms, omit_null_fields, record),
        .text => try writeTextRecordBody(writer, timestamp_ms, omit_null_fields, record),
        .pretty => try writePrettyRecordBody(writer, timestamp_ms, use_color, omit_null_fields, record),
    }
    try writer.writeByte('\n');
}

fn ensureRecordType(comptime Record: type) void {
    switch (@typeInfo(Record)) {
        .@"struct" => {},
        else => @compileError("log records must be structs"),
    }
    if (@hasField(Record, "timestamp") or @hasField(Record, "timestamp_ms")) {
        @compileError("timestamp and timestamp_ms are reserved for the logger");
    }
}

fn writeJsonRecordBody(
    writer: *std.Io.Writer,
    timestamp_ms: i64,
    omit_null_fields: bool,
    record: anytype,
) !void {
    var timestamp_buffer: [32]u8 = undefined;
    const timestamp = try formatTimestamp(&timestamp_buffer, timestamp_ms);

    try writer.writeByte('{');
    try writeJsonField(writer, "timestamp", timestamp, false);

    const fields = @typeInfo(@TypeOf(record)).@"struct".fields;
    var comma = true;
    inline for (fields) |field| {
        const value = @field(record, field.name);
        if (!(omit_null_fields and isNull(value))) {
            try writeJsonField(writer, field.name, value, comma);
            comma = true;
        }
    }

    try writer.writeByte('}');
}

fn writeJsonField(writer: *std.Io.Writer, name: []const u8, value: anytype, comma: bool) !void {
    if (comma) try writer.writeByte(',');
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeTextRecordBody(
    writer: *std.Io.Writer,
    timestamp_ms: i64,
    omit_null_fields: bool,
    record: anytype,
) !void {
    var timestamp_buffer: [32]u8 = undefined;
    const timestamp = try formatTimestamp(&timestamp_buffer, timestamp_ms);

    try writeTextField(writer, "timestamp", timestamp, false);

    const fields = @typeInfo(@TypeOf(record)).@"struct".fields;
    var space = true;
    inline for (fields) |field| {
        const value = @field(record, field.name);
        if (!(omit_null_fields and isNull(value))) {
            try writeTextField(writer, field.name, value, space);
            space = true;
        }
    }
}

fn writeTextField(writer: *std.Io.Writer, name: []const u8, value: anytype, space: bool) !void {
    if (space) try writer.writeByte(' ');
    try writer.writeAll(name);
    try writer.writeByte('=');
    try std.json.Stringify.value(value, .{}, writer);
}

fn writePrettyRecordBody(
    writer: *std.Io.Writer,
    timestamp_ms: i64,
    use_color: bool,
    omit_null_fields: bool,
    record: anytype,
) !void {
    try writeAnsi(writer, use_color, ansi.dim);
    try writer.writeByte('[');
    try writeTimestamp(writer, timestamp_ms);
    try writer.writeByte(']');
    try writeAnsi(writer, use_color, ansi.reset);

    if (@hasField(@TypeOf(record), "level") and
        !(omit_null_fields and isNull(@field(record, "level"))))
    {
        try writer.writeByte(' ');
        try writePrettyLevel(writer, @field(record, "level"), use_color);
    }

    if (@hasField(@TypeOf(record), "event") and
        !(omit_null_fields and isNull(@field(record, "event"))))
    {
        try writer.writeByte(' ');
        try writeAnsi(writer, use_color, ansi.cyan);
        try writeAnsi(writer, use_color, ansi.bold);
        try writePrettyHeaderValue(writer, @field(record, "event"));
        try writeAnsi(writer, use_color, ansi.reset);
    }

    const fields = @typeInfo(@TypeOf(record)).@"struct".fields;
    inline for (fields) |field| {
        const value = @field(record, field.name);
        if (!(omit_null_fields and isNull(value))) {
            if (comptime std.mem.eql(u8, field.name, "level") or
                std.mem.eql(u8, field.name, "event"))
            {} else {
                try writer.writeByte(' ');
                try writeAnsi(writer, use_color, ansi.dim);
                try writer.writeAll(field.name);
                try writeAnsi(writer, use_color, ansi.reset);
                try writer.writeByte('=');
                try std.json.Stringify.value(value, .{}, writer);
            }
        }
    }
}

fn isNull(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => value == null,
        else => false,
    };
}

fn writePrettyLevel(writer: *std.Io.Writer, value: anytype, use_color: bool) !void {
    if (stringValue(value)) |level| {
        try writeAnsi(writer, use_color, levelColor(level));
        try writeAnsi(writer, use_color, ansi.bold);
        try writePrettyText(writer, prettyLevel(level));
        try writeAnsi(writer, use_color, ansi.reset);
    } else {
        try writePrettyHeaderValue(writer, value);
    }
}

fn writePrettyHeaderValue(writer: *std.Io.Writer, value: anytype) !void {
    if (stringValue(value)) |string| {
        try writePrettyText(writer, string);
    } else {
        try std.json.Stringify.value(value, .{}, writer);
    }
}

fn stringValue(value: anytype) ?[]const u8 {
    const Value = @TypeOf(value);
    if (Value == []const u8) return value;

    switch (@typeInfo(Value)) {
        .pointer => |pointer| {
            if (pointer.size == .slice and pointer.child == u8) return value;
            switch (@typeInfo(pointer.child)) {
                .array => |array| {
                    if (array.child == u8) return value.*[0..array.len];
                },
                else => {},
            }
        },
        else => {},
    }
    return null;
}

fn writePrettyText(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789abcdef";
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            try writer.writeAll("\\x");
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        } else {
            try writer.writeByte(byte);
        }
    }
}

fn writeAnsi(writer: *std.Io.Writer, enabled: bool, code: []const u8) !void {
    if (enabled) try writer.writeAll(code);
}

fn levelColor(level: []const u8) []const u8 {
    if (std.mem.eql(u8, level, "info")) return ansi.green;
    if (std.mem.eql(u8, level, "warn")) return ansi.yellow;
    if (std.mem.eql(u8, level, "error")) return ansi.red;
    return ansi.cyan;
}

fn prettyLevel(level: []const u8) []const u8 {
    if (std.mem.eql(u8, level, "info")) return "INFO";
    if (std.mem.eql(u8, level, "warn")) return "WARN";
    if (std.mem.eql(u8, level, "error")) return "ERROR";
    return level;
}

fn formatTimestamp(buffer: []u8, timestamp_ms: i64) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writeTimestamp(&writer, timestamp_ms);
    return writer.buffered();
}

fn writeTimestamp(writer: *std.Io.Writer, timestamp_ms: i64) !void {
    if (timestamp_ms < 0) return error.TimestampOutOfRange;

    const seconds = @divFloor(timestamp_ms, @as(i64, 1000));
    const milliseconds: u16 = @intCast(@mod(timestamp_ms, @as(i64, 1000)));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    try writePadded(writer, year_day.year, 4);
    try writer.writeByte('-');
    try writePadded(writer, month_day.month.numeric(), 2);
    try writer.writeByte('-');
    try writePadded(writer, @as(u8, month_day.day_index) + 1, 2);
    try writer.writeByte('T');
    try writePadded(writer, day_seconds.getHoursIntoDay(), 2);
    try writer.writeByte(':');
    try writePadded(writer, day_seconds.getMinutesIntoHour(), 2);
    try writer.writeByte(':');
    try writePadded(writer, day_seconds.getSecondsIntoMinute(), 2);
    try writer.writeByte('.');
    try writePadded(writer, milliseconds, 3);
    try writer.writeByte('Z');
}

fn writePadded(writer: *std.Io.Writer, value: anytype, width: usize) !void {
    var buffer: [32]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    var padding = if (rendered.len < width) width - rendered.len else 0;
    while (padding > 0) : (padding -= 1) {
        try writer.writeByte('0');
    }
    try writer.writeAll(rendered);
}

test "generic records are JSON lines with logger-owned timestamps" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeRecord(&writer, .json, 1_735_689_600_000, false, false, .{
        .level = "info",
        .event = "http.request",
        .method = "GET",
        .target = "/notes/hello?draft=true",
        .status = 200,
        .duration_ms = 3,
        .error_name = null,
    });

    try std.testing.expectEqualStrings(
        "{\"timestamp\":\"2025-01-01T00:00:00.000Z\",\"level\":\"info\",\"event\":\"http.request\",\"method\":\"GET\",\"target\":\"/notes/hello?draft=true\",\"status\":200,\"duration_ms\":3,\"error_name\":null}\n",
        writer.buffered(),
    );
}

test "generic records support text and pretty formats" {
    var text_buffer: [1024]u8 = undefined;
    var text_writer = std.Io.Writer.fixed(&text_buffer);
    const record = .{
        .level = @as([]const u8, "info"),
        .event = @as([]const u8, "http.request"),
        .method = @as([]const u8, "GET"),
        .target = @as([]const u8, "/notes/hello"),
        .status = @as(?u16, 200),
        .duration_ms = @as(i64, 3),
        .error_name = @as(?[]const u8, null),
    };

    try writeRecord(&text_writer, .text, 1_735_689_600_000, false, false, record);
    try std.testing.expectEqualStrings(
        "timestamp=\"2025-01-01T00:00:00.000Z\" level=\"info\" event=\"http.request\" method=\"GET\" target=\"/notes/hello\" status=200 duration_ms=3 error_name=null\n",
        text_writer.buffered(),
    );

    var pretty_buffer: [1024]u8 = undefined;
    var pretty_writer = std.Io.Writer.fixed(&pretty_buffer);
    try writeRecord(&pretty_writer, .pretty, 1_735_689_600_000, false, false, record);
    try std.testing.expectEqualStrings(
        "[2025-01-01T00:00:00.000Z] INFO http.request method=\"GET\" target=\"/notes/hello\" status=200 duration_ms=3 error_name=null\n",
        pretty_writer.buffered(),
    );
}

test "pretty formatting accepts a non-request record" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeRecord(&writer, .pretty, 42, false, false, .{
        .level = "info",
        .event = "startup",
        .component = @as([]const u8, "runtime"),
        .message = @as([]const u8, "ready"),
    });

    try std.testing.expectEqualStrings(
        "[1970-01-01T00:00:00.042Z] INFO startup component=\"runtime\" message=\"ready\"\n",
        writer.buffered(),
    );
}

test "pretty formatting colors the timestamp, level, event, and fields" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeRecord(&writer, .pretty, 42, true, false, .{
        .level = "error",
        .event = "startup.failed",
        .message = @as([]const u8, "unavailable"),
    });

    try std.testing.expectEqualStrings(
        "\x1b[2m[1970-01-01T00:00:00.042Z]\x1b[0m \x1b[31m\x1b[1mERROR\x1b[0m \x1b[36m\x1b[1mstartup.failed\x1b[0m \x1b[2mmessage\x1b[0m=\"unavailable\"\n",
        writer.buffered(),
    );
}

test "pretty formatting escapes control characters in headers" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeRecord(&writer, .pretty, 42, false, false, .{
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
        .duration_ms = @as(i64, 3),
    };

    var json_buffer: [1024]u8 = undefined;
    var json_writer = std.Io.Writer.fixed(&json_buffer);
    try writeRecord(&json_writer, .json, 42, false, true, record);
    try std.testing.expectEqualStrings(
        "{\"timestamp\":\"1970-01-01T00:00:00.042Z\",\"level\":\"info\",\"event\":\"http.request\",\"duration_ms\":3}\n",
        json_writer.buffered(),
    );

    var text_buffer: [1024]u8 = undefined;
    var text_writer = std.Io.Writer.fixed(&text_buffer);
    try writeRecord(&text_writer, .text, 42, false, true, record);
    try std.testing.expectEqualStrings(
        "timestamp=\"1970-01-01T00:00:00.042Z\" level=\"info\" event=\"http.request\" duration_ms=3\n",
        text_writer.buffered(),
    );

    var pretty_buffer: [1024]u8 = undefined;
    var pretty_writer = std.Io.Writer.fixed(&pretty_buffer);
    try writeRecord(&pretty_writer, .pretty, 42, false, true, record);
    try std.testing.expectEqualStrings(
        "[1970-01-01T00:00:00.042Z] INFO http.request duration_ms=3\n",
        pretty_writer.buffered(),
    );
}
