const std = @import("std");
const ast = @import("ast.zig");

pub fn parsePath(comptime expression: []const u8, comptime capacity: usize) ast.Path(capacity) {
    const trimmed = std.mem.trim(u8, expression, " \t\r\n");
    if (trimmed.len == 0) @compileError("template interpolation cannot be empty");

    comptime var path: ast.Path(capacity) = .{
        .source = trimmed,
        .segments = undefined,
        .count = 0,
    };
    comptime var segment_start: usize = 0;
    comptime var index: usize = 0;
    inline while (index <= trimmed.len) : (index += 1) {
        if (index != trimmed.len and trimmed[index] != '.') continue;

        const raw_segment = trimmed[segment_start..index];
        const left = trimLeft(raw_segment);
        const right = trimRight(raw_segment);
        if (left >= right or !isIdentifier(trimmed[left + segment_start .. right + segment_start])) {
            @compileError("template paths require valid field identifiers");
        }
        if (path.count == capacity) @compileError("template paths exceed the maximum segment count");
        path.segments[path.count] = .{
            .start = left + segment_start,
            .len = right - left,
        };
        path.count += 1;
        segment_start = index + 1;
    }
    return path;
}

pub fn isIdentifier(value: []const u8) bool {
    if (value.len == 0 or !isIdentifierStart(value[0])) return false;
    for (value[1..]) |character| {
        if (!isIdentifierContinue(character)) return false;
    }
    return true;
}

fn trimLeft(value: []const u8) usize {
    var index: usize = 0;
    while (index < value.len and isWhitespace(value[index])) : (index += 1) {}
    return index;
}

fn trimRight(value: []const u8) usize {
    var index: usize = value.len;
    while (index > 0 and isWhitespace(value[index - 1])) : (index -= 1) {}
    return index;
}

fn isWhitespace(character: u8) bool {
    return character == ' ' or character == '\t' or character == '\r' or character == '\n';
}

fn isIdentifierStart(character: u8) bool {
    return character == '_' or
        character >= 'a' and character <= 'z' or
        character >= 'A' and character <= 'Z';
}

fn isIdentifierContinue(character: u8) bool {
    return isIdentifierStart(character) or character >= '0' and character <= '9';
}
