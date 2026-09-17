const std = @import("std");
const ast = @import("ast.zig");

const Stop = enum { root, if_block, for_block };
const SequenceEnd = enum { end, else_tag, if_close, for_close };

pub fn parse(comptime source: []const u8) ast.Parsed(source.len) {
    @setEvalBranchQuota(10_000 + source.len * 100);
    comptime var state: Parser(source.len) = .{
        .source = source,
        .parsed = .{ .nodes = undefined, .count = 0 },
        .cursor = 0,
    };

    comptime {
        _ = parseSequence(&state, .root);
    }
    return state.parsed;
}

fn Parser(comptime capacity: usize) type {
    return struct {
        source: []const u8,
        parsed: ast.Parsed(capacity),
        cursor: usize,
    };
}

fn parseSequence(state: anytype, comptime stop: Stop) SequenceEnd {
    const source = state.source;
    while (state.cursor < source.len) {
        const open = find(source, state.cursor, "{{") orelse {
            appendText(&state.parsed, source[state.cursor..]);
            state.cursor = source.len;
            return .end;
        };

        if (open > state.cursor) appendText(&state.parsed, source[state.cursor..open]);

        const raw = open + 2 < source.len and source[open + 2] == '{';
        const body_start = open + if (raw) 3 else 2;
        const close_token = if (raw) "}}}" else "}}";
        const close = find(source, body_start, close_token) orelse
            @compileError("unclosed template interpolation");

        if (!raw and close + 2 < source.len and source[close + 2] == '}') {
            @compileError("triple-brace interpolation requires three closing braces");
        }

        const token = std.mem.trim(u8, source[body_start..close], " \t\r\n");
        if (token.len == 0) @compileError("template directive cannot be empty");

        if (raw) {
            appendNode(&state.parsed, .{ .raw_expression = parsePath(token, source.len) });
            state.cursor = close + close_token.len;
            continue;
        }

        if (token[0] == '!') {
            state.cursor = close + close_token.len;
            continue;
        }

        if (token[0] == '>') {
            appendNode(&state.parsed, .{ .component = parseComponent(token[1..], source.len) });
            state.cursor = close + close_token.len;
            continue;
        }

        if (token[0] == '#') {
            const header = std.mem.trim(u8, token[1..], " \t\r\n");
            if (startsKeyword(header, "if")) {
                const parsed_header = parseIfHeader(header[2..], source.len);
                const node_index = state.parsed.count;
                appendNode(&state.parsed, .{ .if_block = .{
                    .condition = parsed_header.condition,
                    .capture = parsed_header.capture,
                    .body_start = 0,
                    .body_end = 0,
                    .else_start = 0,
                    .else_end = 0,
                    .node_end = 0,
                } });
                state.cursor = close + close_token.len;
                const body_start_index = state.parsed.count;
                const body_end = parseSequence(state, .if_block);
                const body_end_index = state.parsed.count;
                var else_start_index: usize = 0;
                var else_end_index: usize = 0;
                if (body_end == .else_tag) {
                    else_start_index = state.parsed.count;
                    const close_result = parseSequence(state, .if_block);
                    if (close_result != .if_close) @compileError("unclosed template if block");
                    else_end_index = state.parsed.count;
                } else if (body_end != .if_close) {
                    @compileError("unclosed template if block");
                }
                state.parsed.nodes[node_index].if_block.body_start = body_start_index;
                state.parsed.nodes[node_index].if_block.body_end = body_end_index;
                state.parsed.nodes[node_index].if_block.else_start = else_start_index;
                state.parsed.nodes[node_index].if_block.else_end = else_end_index;
                state.parsed.nodes[node_index].if_block.node_end = state.parsed.count;
                continue;
            }
            if (startsKeyword(header, "for")) {
                const parsed_header = parseForHeader(header[3..], source.len);
                const node_index = state.parsed.count;
                appendNode(&state.parsed, .{ .for_block = .{
                    .iterable = parsed_header.iterable,
                    .capture = parsed_header.capture,
                    .body_start = 0,
                    .body_end = 0,
                    .node_end = 0,
                } });
                state.cursor = close + close_token.len;
                const body_start_index = state.parsed.count;
                const close_result = parseSequence(state, .for_block);
                if (close_result != .for_close) @compileError("unclosed template for block");
                state.parsed.nodes[node_index].for_block.body_start = body_start_index;
                state.parsed.nodes[node_index].for_block.body_end = state.parsed.count;
                state.parsed.nodes[node_index].for_block.node_end = state.parsed.count;
                continue;
            }
            if (std.mem.eql(u8, header, "else")) {
                if (stop != .if_block) @compileError("unexpected template else directive");
                state.cursor = close + close_token.len;
                return .else_tag;
            }
            @compileError("unknown template block directive");
        }

        if (token[0] == '/') {
            const name = std.mem.trim(u8, token[1..], " \t\r\n");
            if (std.mem.eql(u8, name, "if")) {
                if (stop != .if_block) @compileError("unexpected template if closer");
                state.cursor = close + close_token.len;
                return .if_close;
            }
            if (std.mem.eql(u8, name, "for")) {
                if (stop != .for_block) @compileError("unexpected template for closer");
                state.cursor = close + close_token.len;
                return .for_close;
            }
            @compileError("unknown template block closer");
        }

        appendNode(&state.parsed, .{ .expression = parsePath(token, source.len) });
        state.cursor = close + close_token.len;
    }

    if (stop == .if_block) @compileError("unclosed template if block");
    if (stop == .for_block) @compileError("unclosed template for block");
    return .end;
}

fn appendNode(parsed: anytype, node: @TypeOf(parsed.nodes[0])) void {
    parsed.nodes[parsed.count] = node;
    parsed.count += 1;
}

fn appendText(parsed: anytype, text: []const u8) void {
    if (text.len == 0) return;
    appendNode(parsed, .{ .text = text });
}

fn find(comptime source: []const u8, start: usize, comptime needle: []const u8) ?usize {
    comptime var index = start;
    inline while (index + needle.len <= source.len) : (index += 1) {
        if (std.mem.eql(u8, source[index .. index + needle.len], needle)) return index;
    }
    return null;
}

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
        path.segments[path.count] = .{
            .start = left + segment_start,
            .len = right - left,
        };
        path.count += 1;
        segment_start = index + 1;
    }
    return path;
}

fn IfHeader(comptime capacity: usize) type {
    return struct {
        condition: ast.Path(capacity),
        capture: ?[]const u8,
    };
}

fn ForHeader(comptime capacity: usize) type {
    return struct {
        iterable: ast.Path(capacity),
        capture: []const u8,
    };
}

fn parseIfHeader(comptime value: []const u8, comptime capacity: usize) IfHeader(capacity) {
    const rest = std.mem.trim(u8, value, " \t\r\n");
    if (rest.len == 0) @compileError("if directive requires a condition");
    return parseOptionalCaptureHeader(rest, capacity, "if");
}

fn parseForHeader(comptime value: []const u8, comptime capacity: usize) ForHeader(capacity) {
    const rest = std.mem.trim(u8, value, " \t\r\n");
    const first = std.mem.indexOfScalar(u8, rest, '|') orelse
        @compileError("for directive requires a capture");
    const second_relative = std.mem.indexOfScalar(u8, rest[first + 1 ..], '|') orelse
        @compileError("for directive requires a closing capture bar");
    const second = first + 1 + second_relative;
    if (std.mem.indexOfScalar(u8, rest[second + 1 ..], '|') != null) {
        @compileError("for directive has malformed capture syntax");
    }
    if (std.mem.trim(u8, rest[second + 1 ..], " \t\r\n").len != 0) {
        @compileError("for directive has malformed capture syntax");
    }
    const iterable = std.mem.trim(u8, rest[0..first], " \t\r\n");
    const capture = std.mem.trim(u8, rest[first + 1 .. second], " \t\r\n");
    if (iterable.len == 0 or capture.len == 0 or !isIdentifier(capture)) {
        @compileError("for directive has malformed capture syntax");
    }
    return .{ .iterable = parsePath(iterable, capacity), .capture = capture };
}

fn parseOptionalCaptureHeader(comptime rest: []const u8, comptime capacity: usize, comptime directive: []const u8) IfHeader(capacity) {
    const first = std.mem.indexOfScalar(u8, rest, '|') orelse
        return .{ .condition = parsePath(rest, capacity), .capture = null };
    const second_relative = std.mem.indexOfScalar(u8, rest[first + 1 ..], '|') orelse
        @compileError(std.fmt.comptimePrint("{s} directive has malformed capture syntax", .{directive}));
    const second = first + 1 + second_relative;
    if (std.mem.indexOfScalar(u8, rest[second + 1 ..], '|') != null) {
        @compileError(std.fmt.comptimePrint("{s} directive has malformed capture syntax", .{directive}));
    }
    if (std.mem.trim(u8, rest[second + 1 ..], " \t\r\n").len != 0) {
        @compileError(std.fmt.comptimePrint("{s} directive has malformed capture syntax", .{directive}));
    }
    const condition = std.mem.trim(u8, rest[0..first], " \t\r\n");
    const capture = std.mem.trim(u8, rest[first + 1 .. second], " \t\r\n");
    if (condition.len == 0 or capture.len == 0 or !isIdentifier(capture)) {
        @compileError(std.fmt.comptimePrint("{s} directive has malformed capture syntax", .{directive}));
    }
    return .{ .condition = parsePath(condition, capacity), .capture = capture };
}

fn parseComponent(comptime value: []const u8, comptime capacity: usize) ast.Component(capacity) {
    comptime var component: ast.Component(capacity) = .{
        .name = undefined,
        .args = undefined,
        .count = 0,
    };
    comptime var cursor: usize = 0;
    skipWhitespace(value, &cursor);

    const name_start = cursor;
    while (cursor < value.len and !isWhitespace(value[cursor])) : (cursor += 1) {}
    const name = value[name_start..cursor];
    if (!isIdentifier(name)) @compileError("component calls require a valid component name");
    component.name = name;

    while (true) {
        skipWhitespace(value, &cursor);
        if (cursor == value.len) break;

        const argument_start = cursor;
        while (cursor < value.len and !isWhitespace(value[cursor]) and value[cursor] != '=') : (cursor += 1) {}
        const argument_name = value[argument_start..cursor];
        if (!isIdentifier(argument_name)) @compileError("component calls require valid argument names");
        skipWhitespace(value, &cursor);
        if (cursor == value.len or value[cursor] != '=') {
            @compileError("component arguments require '='");
        }
        cursor += 1;
        skipWhitespace(value, &cursor);
        if (cursor == value.len) @compileError("component arguments require a value");

        const expression_start = cursor;
        if (value[cursor] == '"' or value[cursor] == '\'') {
            const quote = value[cursor];
            cursor += 1;
            while (cursor < value.len and value[cursor] != quote) : (cursor += 1) {}
            if (cursor == value.len) @compileError("unclosed component string literal");
            cursor += 1;
        } else {
            while (cursor < value.len and !isWhitespace(value[cursor])) : (cursor += 1) {}
        }
        const expression_text = value[expression_start..cursor];
        component.args[component.count] = .{
            .name = argument_name,
            .value = parseComponentExpr(expression_text, capacity),
        };
        component.count += 1;
    }
    return component;
}

fn parseComponentExpr(comptime value: []const u8, comptime capacity: usize) ast.Expr {
    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
        if (std.mem.indexOfScalar(u8, value[1 .. value.len - 1], '\\') != null) {
            @compileError("component string literal escapes are not supported");
        }
        return .{ .string = value[1 .. value.len - 1] };
    }
    if (std.mem.eql(u8, value, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, value, "false")) return .{ .boolean = false };
    if (isIntegerLiteral(value)) {
        const integer = std.fmt.parseInt(i64, value, 10) catch
            @compileError("component integer literal is out of range");
        return .{ .integer = integer };
    }
    _ = parsePath(value, capacity);
    return .{ .path = value };
}

fn skipWhitespace(value: []const u8, cursor: *usize) void {
    while (cursor.* < value.len and isWhitespace(value[cursor.*])) : (cursor.* += 1) {}
}

fn isIntegerLiteral(value: []const u8) bool {
    if (value.len == 0) return false;
    var start: usize = 0;
    if (value[0] == '-') {
        if (value.len == 1) return false;
        start = 1;
    }
    for (value[start..]) |character| {
        if (character < '0' or character > '9') return false;
    }
    return true;
}

fn startsKeyword(value: []const u8, keyword: []const u8) bool {
    return value.len >= keyword.len and std.mem.eql(u8, value[0..keyword.len], keyword) and
        (value.len == keyword.len or isWhitespace(value[keyword.len]));
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
