const std = @import("std");

pub fn ensureRecordType(comptime Record: type) void {
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

pub fn comptimeFormatTemplate(comptime Record: type) ?[]const u8 {
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

pub fn formatTemplateUsesField(comptime template: []const u8, comptime name: []const u8) bool {
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

pub fn writeFormatTemplate(
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
    if (escape_controls) return writeEscapedText(writer, value);
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

pub fn isNull(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => value == null,
        else => false,
    };
}

pub fn stringValue(value: anytype) ?[]const u8 {
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

pub fn writeEscapedText(writer: *std.Io.Writer, value: []const u8) !void {
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

pub fn formatTimestamp(buffer: []u8, timestamp_ms: i64) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writeTimestamp(&writer, timestamp_ms);
    return writer.buffered();
}

pub fn writeTimestamp(writer: *std.Io.Writer, timestamp_ms: i64) !void {
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
