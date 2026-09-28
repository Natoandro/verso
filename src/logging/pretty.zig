const std = @import("std");
const format = @import("format.zig");

const ansi = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const bold = "\x1b[1m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const cyan = "\x1b[36m";
};

pub fn writeRecordBody(
    writer: *std.Io.Writer,
    timestamp_ms: i64,
    use_color: bool,
    omit_null_fields: bool,
    record: anytype,
) !void {
    try writeAnsi(writer, use_color, ansi.dim);
    try writer.writeByte('[');
    try format.writeTimestamp(writer, timestamp_ms);
    try writer.writeByte(']');
    try writeAnsi(writer, use_color, ansi.reset);

    if (@hasField(@TypeOf(record), "level") and
        !(omit_null_fields and format.isNull(@field(record, "level"))))
    {
        try writer.writeByte(' ');
        try writePrettyLevel(writer, @field(record, "level"), use_color);
    }

    var wrote_header = false;
    if (comptime format.comptimeFormatTemplate(@TypeOf(record))) |template| {
        try writer.writeByte(' ');
        try writeAnsi(writer, use_color, ansi.cyan);
        try writeAnsi(writer, use_color, ansi.bold);
        try format.writeFormatTemplate(writer, template, record, true);
        try writeAnsi(writer, use_color, ansi.reset);
        wrote_header = true;
    } else if (@hasField(@TypeOf(record), "message") and
        !format.isNull(@field(record, "message")))
    {
        try writer.writeByte(' ');
        try writePrettyHeadline(writer, @field(record, "message"), use_color);
        wrote_header = true;
    }

    if (!wrote_header and @hasField(@TypeOf(record), "event") and
        !format.isNull(@field(record, "event")))
    {
        try writer.writeByte(' ');
        try writePrettyHeadline(writer, @field(record, "event"), use_color);
    }

    const fields = @typeInfo(@TypeOf(record)).@"struct".fields;
    inline for (fields) |field| {
        const value = @field(record, field.name);
        if (!omitPrettyField(field, comptime format.comptimeFormatTemplate(@TypeOf(record))) and
            !(omit_null_fields and format.isNull(value)))
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
    return format.formatTemplateUsesField(template.?, field.name);
}

fn writePrettyHeadline(writer: *std.Io.Writer, value: anytype, use_color: bool) !void {
    try writeAnsi(writer, use_color, ansi.cyan);
    try writeAnsi(writer, use_color, ansi.bold);
    try writePrettyHeaderValue(writer, value);
    try writeAnsi(writer, use_color, ansi.reset);
}

fn writePrettyLevel(writer: *std.Io.Writer, value: anytype, use_color: bool) !void {
    if (format.stringValue(value)) |level| {
        if (std.mem.eql(u8, level, "debug")) {
            try writeAnsi(writer, use_color, ansi.dim);
            try format.writeEscapedText(writer, prettyLevel(level));
            try writeAnsi(writer, use_color, ansi.reset);
            return;
        }
        try writeAnsi(writer, use_color, levelColor(level));
        try writeAnsi(writer, use_color, ansi.bold);
        try format.writeEscapedText(writer, prettyLevel(level));
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
    if (format.stringValue(value)) |string| {
        try format.writeEscapedText(writer, string);
    } else {
        try std.json.Stringify.value(value, .{}, writer);
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
    if (std.mem.eql(u8, level, "debug")) return "DEBUG";
    return level;
}
