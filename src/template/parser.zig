const std = @import("std");
const ast = @import("ast.zig");

pub fn parse(comptime source: []const u8) ast.Parsed(source.len) {
    @setEvalBranchQuota(10_000 + source.len * 100);
    comptime var parsed: ast.Parsed(source.len) = .{
        .nodes = undefined,
        .count = 0,
    };
    comptime var cursor: usize = 0;

    inline while (cursor < source.len) {
        const open = find(source, cursor, "{{") orelse {
            appendText(&parsed, source[cursor..]);
            cursor = source.len;
            continue;
        };

        if (open > cursor) appendText(&parsed, source[cursor..open]);

        const raw = open + 2 < source.len and source[open + 2] == '{';
        const body_start = open + if (raw) 3 else 2;
        const close_token = if (raw) "}}}" else "}}";
        const close = find(source, body_start, close_token) orelse
            @compileError("unclosed template interpolation");

        if (!raw and close + 2 < source.len and source[close + 2] == '}') {
            @compileError("triple-brace interpolation requires three closing braces");
        }

        const expression = parsePath(source[body_start..close], source.len);
        if (raw) {
            parsed.nodes[parsed.count] = .{ .raw_expression = expression };
        } else {
            parsed.nodes[parsed.count] = .{ .expression = expression };
        }
        parsed.count += 1;
        cursor = close + close_token.len;
    }

    return parsed;
}

fn appendText(parsed: anytype, text: []const u8) void {
    if (text.len == 0) return;
    parsed.nodes[parsed.count] = .{ .text = text };
    parsed.count += 1;
}

fn find(comptime source: []const u8, start: usize, comptime needle: []const u8) ?usize {
    comptime var index = start;
    inline while (index + needle.len <= source.len) : (index += 1) {
        if (std.mem.eql(u8, source[index .. index + needle.len], needle)) return index;
    }
    return null;
}

fn parsePath(comptime expression: []const u8, comptime capacity: usize) ast.Path(capacity) {
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
        path.segments[path.count] = .{
            .start = left + segment_start,
            .len = right - left,
        };
        path.count += 1;
        segment_start = index + 1;
    }
    return path;
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

fn isIdentifier(value: []const u8) bool {
    if (value.len == 0 or !isIdentifierStart(value[0])) return false;
    for (value[1..]) |character| {
        if (!isIdentifierContinue(character)) return false;
    }
    return true;
}

fn isIdentifierStart(character: u8) bool {
    return character == '_' or
        character >= 'a' and character <= 'z' or
        character >= 'A' and character <= 'Z';
}

fn isIdentifierContinue(character: u8) bool {
    return isIdentifierStart(character) or character >= '0' and character <= '9';
}
