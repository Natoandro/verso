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

pub const Logger = struct {
    allocator: std.mem.Allocator,
    format: ResolvedFormat,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, format: ResolvedFormat) Logger {
        return .{
            .allocator = allocator,
            .format = format,
        };
    }

    /// Writes one structured log record. The record may be any struct; the
    /// logger adds the wall-clock timestamp to the serialized output.
    ///
    /// `timestamp_ms` is reserved for the logger and must not be a field in
    /// the supplied record. `level` and `event` are conventional fields used
    /// by the pretty formatter when present, but are not otherwise required.
    pub fn log(self: *Logger, io: std.Io, record: anytype) std.Io.Cancelable!void {
        const timestamp_ms = std.Io.Clock.now(.real, io).toMilliseconds();

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        var output = std.Io.Writer.Allocating.init(self.allocator);
        defer output.deinit();
        writeRecord(&output.writer, self.format, timestamp_ms, record) catch return;

        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &buffer);
        writer.interface.writeAll(output.written()) catch return;
        writer.flush() catch return;
    }
};

fn writeRecord(
    writer: *std.Io.Writer,
    format: ResolvedFormat,
    timestamp_ms: i64,
    record: anytype,
) !void {
    ensureRecordType(@TypeOf(record));

    switch (format) {
        .json => try writeJsonRecordBody(writer, timestamp_ms, record),
        .text => try writeTextRecordBody(writer, timestamp_ms, record),
        .pretty => try writePrettyRecordBody(writer, timestamp_ms, record),
    }
    try writer.writeByte('\n');
}

fn ensureRecordType(comptime Record: type) void {
    switch (@typeInfo(Record)) {
        .@"struct" => {},
        else => @compileError("log records must be structs"),
    }
    if (@hasField(Record, "timestamp_ms")) {
        @compileError("timestamp_ms is reserved for the logger");
    }
}

fn writeJsonRecordBody(
    writer: *std.Io.Writer,
    timestamp_ms: i64,
    record: anytype,
) !void {
    try writer.writeByte('{');
    try writeJsonField(writer, "timestamp_ms", timestamp_ms, false);

    const fields = @typeInfo(@TypeOf(record)).@"struct".fields;
    inline for (fields) |field| {
        try writeJsonField(writer, field.name, @field(record, field.name), true);
    }

    try writer.writeByte('}');
}

fn writeJsonField(writer: *std.Io.Writer, name: []const u8, value: anytype, comma: bool) !void {
    if (comma) try writer.writeByte(',');
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeTextRecordBody(writer: *std.Io.Writer, timestamp_ms: i64, record: anytype) !void {
    try writeTextField(writer, "timestamp_ms", timestamp_ms, false);

    const fields = @typeInfo(@TypeOf(record)).@"struct".fields;
    inline for (fields) |field| {
        try writeTextField(writer, field.name, @field(record, field.name), true);
    }
}

fn writeTextField(writer: *std.Io.Writer, name: []const u8, value: anytype, space: bool) !void {
    if (space) try writer.writeByte(' ');
    try writer.writeAll(name);
    try writer.writeByte('=');
    try std.json.Stringify.value(value, .{}, writer);
}

fn writePrettyRecordBody(writer: *std.Io.Writer, timestamp_ms: i64, record: anytype) !void {
    try writer.print("[{d}]", .{timestamp_ms});

    if (@hasField(@TypeOf(record), "level")) {
        try writer.writeByte(' ');
        try writePrettyLevel(writer, @field(record, "level"));
    }

    if (@hasField(@TypeOf(record), "event")) {
        try writer.writeByte(' ');
        try writePrettyHeaderValue(writer, @field(record, "event"));
    }

    const fields = @typeInfo(@TypeOf(record)).@"struct".fields;
    inline for (fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "level") or
            std.mem.eql(u8, field.name, "event")) continue;
        try writer.writeByte(' ');
        try writer.writeAll(field.name);
        try writer.writeByte('=');
        try std.json.Stringify.value(@field(record, field.name), .{}, writer);
    }
}

fn writePrettyLevel(writer: *std.Io.Writer, value: anytype) !void {
    if (@TypeOf(value) == []const u8) {
        try writer.writeAll(prettyLevel(value));
    } else {
        try writePrettyHeaderValue(writer, value);
    }
}

fn writePrettyHeaderValue(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn prettyLevel(level: []const u8) []const u8 {
    if (std.mem.eql(u8, level, "info")) return "INFO";
    if (std.mem.eql(u8, level, "warn")) return "WARN";
    if (std.mem.eql(u8, level, "error")) return "ERROR";
    return level;
}

test "generic records are JSON lines with logger-owned timestamps" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeRecord(&writer, .json, 1_735_689_600_000, .{
        .level = "info",
        .event = "http.request",
        .method = "GET",
        .target = "/notes/hello?draft=true",
        .status = 200,
        .duration_ms = 3,
        .error_name = null,
    });

    try std.testing.expectEqualStrings(
        "{\"timestamp_ms\":1735689600000,\"level\":\"info\",\"event\":\"http.request\",\"method\":\"GET\",\"target\":\"/notes/hello?draft=true\",\"status\":200,\"duration_ms\":3,\"error_name\":null}\n",
        writer.buffered(),
    );
}

test "generic records support text and pretty formats" {
    var text_buffer: [1024]u8 = undefined;
    var text_writer = std.Io.Writer.fixed(&text_buffer);
    const record = .{
        .level = "info",
        .event = "http.request",
        .method = "GET",
        .target = "/notes/hello",
        .status = @as(?u16, 200),
        .duration_ms = @as(i64, 3),
        .error_name = @as(?[]const u8, null),
    };

    try writeRecord(&text_writer, .text, 1_735_689_600_000, record);
    try std.testing.expectEqualStrings(
        "timestamp_ms=1735689600000 level=\"info\" event=\"http.request\" method=\"GET\" target=\"/notes/hello\" status=200 duration_ms=3 error_name=null\n",
        text_writer.buffered(),
    );

    var pretty_buffer: [1024]u8 = undefined;
    var pretty_writer = std.Io.Writer.fixed(&pretty_buffer);
    try writeRecord(&pretty_writer, .pretty, 1_735_689_600_000, record);
    try std.testing.expectEqualStrings(
        "[1735689600000] INFO http.request method=\"GET\" target=\"/notes/hello\" status=200 duration_ms=3 error_name=null\n",
        pretty_writer.buffered(),
    );
}

test "pretty formatting accepts a non-request record" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeRecord(&writer, .pretty, 42, .{
        .level = "info",
        .event = "startup",
        .component = "runtime",
        .message = "ready",
    });

    try std.testing.expectEqualStrings(
        "[42] INFO startup component=\"runtime\" message=\"ready\"\n",
        writer.buffered(),
    );
}
