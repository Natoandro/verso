const std = @import("std");
const ast = @import("ast.zig");

fn DeclarationScope(comptime capacity: usize) type {
    return struct {
        items: [capacity]usize,
        count: usize,
    };
}

pub fn annotateLocalCalls(parsed: anytype) void {
    const outer: DeclarationScope(parsed.nodes.len) = .{ .items = undefined, .count = 0 };
    annotateRange(parsed, 0, parsed.count, outer);
}

fn annotateRange(parsed: anytype, comptime start: usize, comptime end: usize, outer: anytype) void {
    const capacity = parsed.nodes.len;
    const direct = collectDeclarations(parsed, start, end, capacity);
    const visible = mergeScopes(direct, outer, capacity);

    comptime var index = start;
    inline while (index < end) : (index += 1) {
        switch (parsed.nodes[index]) {
            .component => {
                const name = parsed.nodes[index].component.name;
                parsed.nodes[index].component.local_decl = findDeclaration(parsed, visible, name);
            },
            .if_block => |block| {
                annotateRange(parsed, block.body_start, block.body_end, visible);
                if (block.else_end > block.else_start) {
                    annotateRange(parsed, block.else_start, block.else_end, visible);
                }
                index = block.node_end - 1;
            },
            .for_block => |block| {
                annotateRange(parsed, block.body_start, block.body_end, visible);
                index = block.node_end - 1;
            },
            .snippet_declaration => |snippet| {
                annotateRange(parsed, snippet.body_start, snippet.body_end, visible);
                index = snippet.node_end - 1;
            },
            else => {},
        }
    }
}

fn collectDeclarations(parsed: anytype, comptime start: usize, comptime end: usize, comptime capacity: usize) DeclarationScope(capacity) {
    comptime var scope: DeclarationScope(capacity) = .{ .items = undefined, .count = 0 };
    comptime var index = start;
    inline while (index < end) : (index += 1) {
        switch (parsed.nodes[index]) {
            .snippet_declaration => |snippet| {
                inline for (scope.items[0..scope.count]) |declaration_index| {
                    if (comptime std.mem.eql(
                        u8,
                        parsed.nodes[declaration_index].snippet_declaration.name,
                        snippet.name,
                    )) {
                        @compileError(std.fmt.comptimePrint(
                            "duplicate snippet name '{s}' in the same scope",
                            .{snippet.name},
                        ));
                    }
                }
                scope.items[scope.count] = index;
                scope.count += 1;
                index = snippet.node_end - 1;
            },
            .if_block => |block| index = block.node_end - 1,
            .for_block => |block| index = block.node_end - 1,
            else => {},
        }
    }
    return scope;
}

fn mergeScopes(comptime direct: anytype, comptime outer: anytype, comptime capacity: usize) DeclarationScope(capacity) {
    comptime var merged: DeclarationScope(capacity) = .{ .items = undefined, .count = 0 };
    inline for (direct.items[0..direct.count]) |index| {
        merged.items[merged.count] = index;
        merged.count += 1;
    }
    inline for (outer.items[0..outer.count]) |index| {
        merged.items[merged.count] = index;
        merged.count += 1;
    }
    return merged;
}

fn findDeclaration(parsed: anytype, comptime scope: anytype, comptime name: []const u8) ?usize {
    inline for (scope.items[0..scope.count]) |index| {
        if (comptime std.mem.eql(u8, parsed.nodes[index].snippet_declaration.name, name)) return index;
    }
    return null;
}

pub fn parseHeader(comptime value: []const u8, comptime capacity: usize) Header(capacity) {
    const rest = std.mem.trim(u8, value, " \t\r\n");
    var name_end: usize = 0;
    while (name_end < rest.len and !isWhitespace(rest[name_end])) : (name_end += 1) {}
    const name = rest[0..name_end];
    if (!isIdentifier(name)) @compileError("snippet declarations require a valid name");

    const parameters_text = std.mem.trim(u8, rest[name_end..], " \t\r\n");
    if (parameters_text.len < 2 or parameters_text[0] != '|') {
        @compileError("snippet declarations require parameters between bars");
    }
    const closing_relative = std.mem.indexOfScalar(u8, parameters_text[1..], '|') orelse
        @compileError("snippet declarations require a closing parameter bar");
    const closing = closing_relative + 1;
    if (std.mem.trim(u8, parameters_text[closing + 1 ..], " \t\r\n").len != 0) {
        @compileError("snippet declarations have malformed parameters");
    }

    comptime var header: Header(capacity) = .{
        .name = name,
        .parameters = undefined,
        .parameter_count = 0,
    };
    const list = std.mem.trim(u8, parameters_text[1..closing], " \t\r\n");
    if (list.len == 0) return header;

    comptime var cursor: usize = 0;
    while (cursor <= list.len) {
        const comma_relative = std.mem.indexOfScalar(u8, list[cursor..], ',');
        const item_end = if (comma_relative) |relative| cursor + relative else list.len;
        const parameter = std.mem.trim(u8, list[cursor..item_end], " \t\r\n");
        if (!isIdentifier(parameter)) @compileError("snippet declarations have malformed parameters");
        inline for (header.parameters[0..header.parameter_count]) |existing| {
            if (comptime std.mem.eql(u8, existing, parameter)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate snippet parameter '{s}'",
                    .{parameter},
                ));
            }
        }
        if (header.parameter_count == header.parameters.len) @compileError("snippet declarations exceed the maximum parameter count");
        header.parameters[header.parameter_count] = parameter;
        header.parameter_count += 1;
        if (item_end == list.len) break;
        cursor = item_end + 1;
    }
    return header;
}

fn Header(comptime capacity: usize) type {
    return struct {
        name: []const u8,
        parameters: [capacity][]const u8,
        parameter_count: usize,
    };
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
    return character == '_' or character >= 'a' and character <= 'z' or character >= 'A' and character <= 'Z';
}

fn isIdentifierContinue(character: u8) bool {
    return isIdentifierStart(character) or character >= '0' and character <= '9';
}
