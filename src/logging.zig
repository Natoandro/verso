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
        var writer = std.Io.File.stderr().writer(io, &buffer);
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
    ensureRecordType(@TypeOf(record));

    switch (format) {
        .json => try writeJsonRecordBody(writer, timestamp_ms, omit_null_fields, record),
        .text => try writeTextRecordBody(writer, allocator, timestamp_ms, omit_null_fields, record),
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

    inline for (@typeInfo(Record).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "format")) {
            if (field.type != []const u8) {
                @compileError("the log record format field must have type []const u8");
            }
            if (!field.is_comptime) {
                @compileError("the log record format field must be comptime");
            }
            if (field.defaultValue() == null) {
                @compileError("a comptime log record format field must have a default value");
            }
            const template = field.defaultValue().?;
            if (template.len > 0) validateFormatTemplate(Record, template);
        }
    }
}

fn comptimeFormatTemplate(comptime Record: type) ?[]const u8 {
    inline for (@typeInfo(Record).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "format")) {
            const template = fieldDefaultValue(field);
            return if (template.len == 0) null else template;
        }
    }
    return null;
}

fn fieldDefaultValue(comptime field: std.builtin.Type.StructField) []const u8 {
    return field.defaultValue().?;
}

fn validateFormatTemplate(comptime Record: type, comptime template: []const u8) void {
    comptime var index: usize = 0;
    inline while (index < template.len) {
        switch (template[index]) {
            '{' => {
                if (index + 1 < template.len and template[index + 1] == '{') {
                    index += 2;
                    continue;
                }
                const start = index + 1;
                index = start;
                inline while (index < template.len and template[index] != '}') : (index += 1) {}
                if (index == template.len or index == start) {
                    @compileError("invalid log record format template");
                }
                const name = comptime template[start..index];
                if (comptime isReservedTemplateField(name) or std.meta.fieldIndex(Record, name) == null) {
                    @compileError("log record format template references an unknown or reserved field");
                }
                index += 1;
            },
            '}' => {
                if (index + 1 >= template.len or template[index + 1] != '}') {
                    @compileError("invalid log record format template");
                }
                index += 2;
            },
            else => index += 1,
        }
    }
}

fn isReservedTemplateField(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "timestamp") or
        std.mem.eql(u8, name, "timestamp_ms") or
        std.mem.eql(u8, name, "format");
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
        if (!omitJsonFormatField(field, record) and !(omit_null_fields and isNull(value))) {
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
    const timestamp = try formatTimestamp(&timestamp_buffer, timestamp_ms);

    try writeTextField(writer, "timestamp", timestamp, false);

    if (comptime comptimeFormatTemplate(@TypeOf(record))) |template| {
        var message = std.Io.Writer.Allocating.init(allocator);
        defer message.deinit();
        try writeFormatTemplate(&message.writer, template, record, false);
        try writeTextField(writer, "message", message.written(), true);
    }

    const fields = @typeInfo(@TypeOf(record)).@"struct".fields;
    var space = true;
    inline for (fields) |field| {
        const value = @field(record, field.name);
        if (!omitTextField(field, comptimeFormatTemplate(@TypeOf(record))) and
            !(omit_null_fields and isNull(value)))
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
    return formatTemplateUsesField(template.?, field.name);
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

    var wrote_header = false;
    if (comptime comptimeFormatTemplate(@TypeOf(record))) |template| {
        try writer.writeByte(' ');
        try writeAnsi(writer, use_color, ansi.cyan);
        try writeAnsi(writer, use_color, ansi.bold);
        try writeFormatTemplate(writer, template, record, true);
        try writeAnsi(writer, use_color, ansi.reset);
        wrote_header = true;
    } else if (@hasField(@TypeOf(record), "message") and
        !isNull(@field(record, "message")))
    {
        try writer.writeByte(' ');
        try writePrettyHeadline(writer, @field(record, "message"), use_color);
        wrote_header = true;
    }

    if (!wrote_header and @hasField(@TypeOf(record), "event") and
        !isNull(@field(record, "event")))
    {
        try writer.writeByte(' ');
        try writePrettyHeadline(writer, @field(record, "event"), use_color);
    }

    const fields = @typeInfo(@TypeOf(record)).@"struct".fields;
    inline for (fields) |field| {
        const value = @field(record, field.name);
        if (!omitPrettyField(field, comptimeFormatTemplate(@TypeOf(record))) and
            !(omit_null_fields and isNull(value)))
        {
            if (comptime std.mem.eql(u8, field.name, "level") or
                std.mem.eql(u8, field.name, "event") or
                std.mem.eql(u8, field.name, "message"))
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

fn omitPrettyField(
    comptime field: std.builtin.Type.StructField,
    comptime template: ?[]const u8,
) bool {
    if (comptime std.mem.eql(u8, field.name, "format") or
        std.mem.eql(u8, field.name, "level") or
        std.mem.eql(u8, field.name, "event") or
        std.mem.eql(u8, field.name, "message")) return true;
    if (template == null) return false;
    return formatTemplateUsesField(template.?, field.name);
}

fn formatTemplateUsesField(comptime template: []const u8, comptime name: []const u8) bool {
    var index: usize = 0;
    while (index < template.len) {
        switch (template[index]) {
            '{' => {
                if (index + 1 < template.len and template[index + 1] == '{') {
                    index += 2;
                    continue;
                }
                const start = index + 1;
                index = start;
                while (index < template.len and template[index] != '}') : (index += 1) {}
                if (index == template.len or index == start) unreachable;
                const field_name = template[start..index];
                if (std.mem.eql(u8, field_name, name)) return true;
                index += 1;
            },
            '}' => {
                if (index + 1 >= template.len or template[index + 1] != '}') {
                    unreachable;
                }
                index += 2;
            },
            else => index += 1,
        }
    }
    return false;
}

fn writeFormatTemplate(
    writer: *std.Io.Writer,
    comptime template: []const u8,
    record: anytype,
    escape_controls: bool,
) !void {
    comptime var index = 0;
    inline while (index < template.len) {
        switch (template[index]) {
            '{' => {
                if (index + 1 < template.len and template[index + 1] == '{') {
                    try writeFormatLiteral(writer, "{", escape_controls);
                    index += 2;
                    continue;
                }
                const start = index + 1;
                index = start;
                inline while (index < template.len and template[index] != '}') : (index += 1) {}
                if (index == template.len or index == start) unreachable;
                try writeFormatField(writer, template[start..index], record, escape_controls);
                index += 1;
            },
            '}' => {
                if (index + 1 >= template.len or template[index + 1] != '}') {
                    unreachable;
                }
                try writeFormatLiteral(writer, "}", escape_controls);
                index += 2;
            },
            else => {
                const start = index;
                inline while (index < template.len and template[index] != '{' and template[index] != '}') : (index += 1) {}
                try writeFormatLiteral(writer, template[start..index], escape_controls);
            },
        }
    }
}

fn writeFormatLiteral(writer: *std.Io.Writer, value: []const u8, escape_controls: bool) !void {
    if (escape_controls) return writePrettyText(writer, value);
    try writer.writeAll(value);
}

fn writeFormatField(writer: *std.Io.Writer, comptime name: []const u8, record: anytype, escape_controls: bool) !void {
    inline for (@typeInfo(@TypeOf(record)).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, name, field.name)) {
            return writeFormatValue(writer, @field(record, field.name), escape_controls);
        }
    }
    unreachable;
}

fn writeFormatValue(writer: *std.Io.Writer, value: anytype, escape_controls: bool) !void {
    if (comptime @typeInfo(@TypeOf(value)) == .optional) {
        if (value) |unwrapped| return writeFormatValue(writer, unwrapped, escape_controls);
        return writer.writeAll("null");
    }
    if (stringValue(value)) |string| return writeFormatLiteral(writer, string, escape_controls);
    if (comptime std.meta.hasFn(@TypeOf(value), "logFormat")) {
        return value.logFormat(writer);
    }
    try std.json.Stringify.value(value, .{}, writer);
}

fn writePrettyHeadline(writer: *std.Io.Writer, value: anytype, use_color: bool) !void {
    try writeAnsi(writer, use_color, ansi.cyan);
    try writeAnsi(writer, use_color, ansi.bold);
    try writePrettyHeaderValue(writer, value);
    try writeAnsi(writer, use_color, ansi.reset);
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
    if (comptime @typeInfo(@TypeOf(value)) == .optional) {
        if (value) |unwrapped| return writePrettyHeaderValue(writer, unwrapped);
        return;
    }
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
        .optional => {
            if (value) |unwrapped| return stringValue(unwrapped);
            return null;
        },
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
