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

pub const RequestRecord = struct {
    timestamp_ms: i64,
    level: []const u8,
    event: []const u8,
    method: ?[]const u8,
    target: ?[]const u8,
    status: ?u16,
    duration_ms: i64,
    error_name: ?[]const u8,
};

pub const Logger = struct {
    allocator: std.mem.Allocator,
    write_record: WriteRecord,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, format: ResolvedFormat) Logger {
        return .{
            .allocator = allocator,
            .write_record = switch (format) {
                .json => writeJsonRecord,
                .text => writeTextRecord,
                .pretty => writePrettyRecord,
            },
        };
    }

    pub fn request(self: *Logger, io: std.Io, record: RequestRecord) std.Io.Cancelable!void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        var output = std.Io.Writer.Allocating.init(self.allocator);
        defer output.deinit();
        self.write_record(&output.writer, record) catch return;

        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &buffer);
        writer.interface.writeAll(output.written()) catch return;
        writer.flush() catch return;
    }
};

const WriteRecord = *const fn (*std.Io.Writer, RequestRecord) anyerror!void;

fn writeRecordLine(
    comptime format: ResolvedFormat,
    writer: *std.Io.Writer,
    record: RequestRecord,
) !void {
    switch (format) {
        .json => try writeJsonRecordBody(writer, record),
        .text => try writeTextRecordBody(writer, record),
        .pretty => try writePrettyRecordBody(writer, record),
    }
    try writer.writeByte('\n');
}

fn writeJsonRecord(writer: *std.Io.Writer, record: RequestRecord) !void {
    try writeRecordLine(.json, writer, record);
}

fn writeTextRecord(writer: *std.Io.Writer, record: RequestRecord) !void {
    try writeRecordLine(.text, writer, record);
}

fn writePrettyRecord(writer: *std.Io.Writer, record: RequestRecord) !void {
    try writeRecordLine(.pretty, writer, record);
}

fn writeJsonRecordBody(writer: *std.Io.Writer, record: RequestRecord) !void {
    try std.json.Stringify.value(record, .{}, writer);
}

fn writeTextRecordBody(writer: *std.Io.Writer, record: anytype) !void {
    const fields = @typeInfo(@TypeOf(record)).@"struct".fields;
    inline for (fields, 0..) |field, index| {
        if (index != 0) try writer.writeByte(' ');
        try writer.writeAll(field.name);
        try writer.writeByte('=');
        try writeTextValue(writer, @field(record, field.name));
    }
}

fn writePrettyRecordBody(writer: *std.Io.Writer, record: RequestRecord) !void {
    try writer.print("[{d}] {s} ", .{ record.timestamp_ms, prettyLevel(record.level) });
    if (record.method) |method| {
        try writer.writeAll(method);
    } else {
        try writer.writeByte('-');
    }
    try writer.writeByte(' ');
    if (record.target) |target| {
        try std.json.Stringify.value(target, .{}, writer);
    } else {
        try writer.writeByte('-');
    }
    try writer.writeAll(" -> ");
    if (record.status) |status| {
        try writer.print("{d}", .{status});
    } else if (record.error_name) |error_name| {
        try writer.print("error={s}", .{error_name});
    } else {
        try writer.writeByte('-');
    }
    try writer.print(" ({d}ms)", .{record.duration_ms});
}

fn writeTextValue(writer: *std.Io.Writer, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .int => try writer.print("{d}", .{value}),
        .optional => if (value) |unwrapped| {
            try writeTextValue(writer, unwrapped);
        } else {
            try writer.writeAll("null");
        },
        .pointer => try std.json.Stringify.value(value, .{}, writer),
        else => @compileError("unsupported text log field type"),
    }
}

fn prettyLevel(level: []const u8) []const u8 {
    if (std.mem.eql(u8, level, "info")) return "INFO";
    if (std.mem.eql(u8, level, "warn")) return "WARN";
    if (std.mem.eql(u8, level, "error")) return "ERROR";
    return level;
}

test "request records are JSON lines" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeJsonRecord(&writer, .{
        .timestamp_ms = 1_735_689_600_000,
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

test "request records support text and pretty formats" {
    var text_buffer: [1024]u8 = undefined;
    var text_writer = std.Io.Writer.fixed(&text_buffer);
    const record: RequestRecord = .{
        .timestamp_ms = 1_735_689_600_000,
        .level = "info",
        .event = "http.request",
        .method = "GET",
        .target = "/notes/hello",
        .status = 200,
        .duration_ms = 3,
        .error_name = null,
    };

    try writeTextRecord(&text_writer, record);
    try std.testing.expectEqualStrings(
        "timestamp_ms=1735689600000 level=\"info\" event=\"http.request\" method=\"GET\" target=\"/notes/hello\" status=200 duration_ms=3 error_name=null\n",
        text_writer.buffered(),
    );

    var pretty_buffer: [1024]u8 = undefined;
    var pretty_writer = std.Io.Writer.fixed(&pretty_buffer);
    try writePrettyRecord(&pretty_writer, record);
    try std.testing.expectEqualStrings(
        "[1735689600000] INFO GET \"/notes/hello\" -> 200 (3ms)\n",
        pretty_writer.buffered(),
    );
}
