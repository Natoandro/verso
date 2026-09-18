const std = @import("std");
const ast = @import("ast.zig");
const path_parser = @import("path_parser.zig");

pub fn parse(comptime value: []const u8, comptime capacity: usize) ast.Component(capacity) {
    comptime var component: ast.Component(capacity) = .{
        .name = undefined,
        .args = undefined,
        .count = 0,
        .local_decl = null,
    };
    comptime var cursor: usize = 0;
    skipWhitespace(value, &cursor);

    const name_start = cursor;
    while (cursor < value.len and !isWhitespace(value[cursor])) : (cursor += 1) {}
    const name = value[name_start..cursor];
    if (!path_parser.isIdentifier(name)) @compileError("component calls require a valid component name");
    component.name = name;

    while (true) {
        skipWhitespace(value, &cursor);
        if (cursor == value.len) break;

        const argument_start = cursor;
        var expression_start: usize = undefined;
        var argument_name: []const u8 = "";
        if (value[cursor] == '"' or value[cursor] == '\'') {
            expression_start = cursor;
            advanceQuoted(value, &cursor);
        } else {
            while (cursor < value.len and !isWhitespace(value[cursor]) and value[cursor] != '=') : (cursor += 1) {}
            const candidate = value[argument_start..cursor];
            const candidate_end = cursor;
            skipWhitespace(value, &cursor);
            if (cursor < value.len and value[cursor] == '=') {
                if (!path_parser.isIdentifier(candidate)) @compileError("component calls require valid argument names");
                argument_name = candidate;
                cursor += 1;
                skipWhitespace(value, &cursor);
                if (cursor == value.len) @compileError("component arguments require a value");
                expression_start = cursor;
                advanceExpression(value, &cursor);
            } else {
                expression_start = argument_start;
                cursor = candidate_end;
            }
        }
        const expression_text = value[expression_start..cursor];
        if (component.count == component.args.len) @compileError("component calls exceed the maximum argument count");
        component.args[component.count] = .{
            .name = argument_name,
            .value = parseExpr(expression_text, capacity),
        };
        component.count += 1;
    }
    return component;
}

fn advanceExpression(value: []const u8, cursor: *usize) void {
    if (value[cursor.*] == '"' or value[cursor.*] == '\'') {
        advanceQuoted(value, cursor);
    } else {
        while (cursor.* < value.len and !isWhitespace(value[cursor.*])) : (cursor.* += 1) {}
    }
}

fn advanceQuoted(value: []const u8, cursor: *usize) void {
    const quote = value[cursor.*];
    cursor.* += 1;
    while (cursor.* < value.len and value[cursor.*] != quote) : (cursor.* += 1) {}
    if (cursor.* == value.len) @compileError("unclosed component string literal");
    cursor.* += 1;
}

fn parseExpr(comptime value: []const u8, comptime capacity: usize) ast.Expr {
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
    _ = path_parser.parsePath(value, capacity);
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

fn isWhitespace(character: u8) bool {
    return character == ' ' or character == '\t' or character == '\r' or character == '\n';
}
