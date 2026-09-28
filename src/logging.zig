const std = @import("std");
const formatting = @import("logging/format.zig");
const pretty = @import("logging/pretty.zig");

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
    /// not be fields in the supplied record. `level`, `event`, and `message`
    /// are conventional fields used by the pretty formatter when present, but
    /// are not otherwise required. `event` is the stable machine-oriented
    /// identifier; `message` is the human-readable description.
    pub fn log(self: *Logger, io: std.Io, record: anytype) !void {
        const timestamp_ms = std.Io.Clock.now(.real, io).toMilliseconds();

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        var output = std.Io.Writer.Allocating.init(self.allocator);
        defer output.deinit();
        try writeRecord(
            &output.writer,
            self.allocator,
            self.format,
            timestamp_ms,
            self.use_color,
            self.omit_null_fields,
            record,
        );

        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stderr().writerStreaming(io, &buffer);
        try writer.interface.writeAll(output.written());
        try writer.flush();
    }
};

pub fn writeRecord(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    format: ResolvedFormat,
    timestamp_ms: i64,
    use_color: bool,
    omit_null_fields: bool,
    record: anytype,
) !void {
    formatting.ensureRecordType(@TypeOf(record));

    switch (format) {
        .json => try writeJsonRecordBody(writer, timestamp_ms, omit_null_fields, record),
        .text => try writeTextRecordBody(writer, allocator, timestamp_ms, omit_null_fields, record),
        .pretty => try pretty.writeRecordBody(writer, timestamp_ms, use_color, omit_null_fields, record),
    }
    try writer.writeByte('\n');
}

fn writeJsonRecordBody(
    writer: *std.Io.Writer,
    timestamp_ms: i64,
    omit_null_fields: bool,
    record: anytype,
) !void {
    var timestamp_buffer: [32]u8 = undefined;
    const timestamp = try formatting.formatTimestamp(&timestamp_buffer, timestamp_ms);

    try writer.writeByte('{');
    try writeJsonField(writer, "timestamp", timestamp, false);

    const fields = @typeInfo(@TypeOf(record)).@"struct".fields;
    var comma = true;
    inline for (fields) |field| {
        const value = @field(record, field.name);
        if (!omitJsonFormatField(field, record) and !(omit_null_fields and formatting.isNull(value))) {
            try writeJsonField(writer, field.name, value, comma);
            comma = true;
        }
    }

    try writer.writeByte('}');
}

fn omitJsonFormatField(comptime field: std.builtin.Type.StructField, record: anytype) bool {
    if (comptime !std.mem.eql(u8, field.name, "format")) return false;
    _ = record;
    return true;
}

fn writeJsonField(writer: *std.Io.Writer, name: []const u8, value: anytype, comma: bool) !void {
    if (comma) try writer.writeByte(',');
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeTextRecordBody(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    timestamp_ms: i64,
    omit_null_fields: bool,
    record: anytype,
) !void {
    var timestamp_buffer: [32]u8 = undefined;
    const timestamp = try formatting.formatTimestamp(&timestamp_buffer, timestamp_ms);

    try writeTextField(writer, "timestamp", timestamp, false);

    if (comptime formatting.comptimeFormatTemplate(@TypeOf(record))) |template| {
        var message = std.Io.Writer.Allocating.init(allocator);
        defer message.deinit();
        try formatting.writeFormatTemplate(&message.writer, template, record, false);
        try writeTextField(writer, "message", message.written(), true);
    }

    const fields = @typeInfo(@TypeOf(record)).@"struct".fields;
    var space = true;
    inline for (fields) |field| {
        const value = @field(record, field.name);
        if (!omitTextField(field, formatting.comptimeFormatTemplate(@TypeOf(record))) and
            !(omit_null_fields and formatting.isNull(value)))
        {
            try writeTextField(writer, field.name, value, space);
            space = true;
        }
    }
}

fn omitTextField(
    comptime field: std.builtin.Type.StructField,
    comptime template: ?[]const u8,
) bool {
    if (comptime std.mem.eql(u8, field.name, "format")) return true;
    if (template == null) return false;
    if (comptime std.mem.eql(u8, field.name, "message")) return true;
    return formatting.formatTemplateUsesField(template.?, field.name);
}

fn writeTextField(writer: *std.Io.Writer, name: []const u8, value: anytype, space: bool) !void {
    if (space) try writer.writeByte(' ');
    try writer.writeAll(name);
    try writer.writeByte('=');
    try std.json.Stringify.value(value, .{}, writer);
}
