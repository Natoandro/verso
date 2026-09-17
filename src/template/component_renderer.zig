const std = @import("std");
const expression = @import("expression.zig");
const parser = @import("parser.zig");

const EmptyContext = struct {};

pub fn renderRegisteredComponent(
    writer: *std.Io.Writer,
    comptime child: anytype,
    comptime call: anytype,
    context: anytype,
) !void {
    const Options = @TypeOf(@TypeOf(child).template_options);
    if (comptime @hasField(Options, "parameters")) {
        const parameters = @TypeOf(child).template_options.parameters;
        const bindings = comptime validateArguments(call, parameters);
        const base: EmptyContext = .{};
        try bindParameters(writer, child, parameters, call, bindings, 0, context, base);
    } else {
        if (call.count != 0) @compileError("component does not declare parameters");
        try child.render(writer, .{});
    }
}

fn validateArguments(comptime call: anytype, comptime parameters: anytype) [parameterCount(parameters)]usize {
    const fields = switch (@typeInfo(@TypeOf(parameters))) {
        .@"struct" => |structure| structure.fields,
        else => @compileError("component parameters must be a struct"),
    };
    comptime var bindings: [fields.len]usize = undefined;
    comptime var bound: [fields.len]bool = [_]bool{false} ** fields.len;

    inline for (call.args[0..call.count], 0..) |argument, argument_index| {
        if (argument.name.len == 0) {
            @compileError(std.fmt.comptimePrint(
                "component '{s}' requires named arguments",
                .{call.name},
            ));
        }
        const parameter_index = findParameter(fields, argument.name) orelse
            @compileError(std.fmt.comptimePrint(
                "unknown argument '{s}' for component '{s}'",
                .{ argument.name, call.name },
            ));
        if (bound[parameter_index]) {
            @compileError(std.fmt.comptimePrint(
                "duplicate argument '{s}' for component '{s}'",
                .{ argument.name, call.name },
            ));
        }
        bound[parameter_index] = true;
        bindings[parameter_index] = argument_index;
    }

    inline for (fields, 0..) |field, parameter_index| {
        if (!bound[parameter_index]) {
            @compileError(std.fmt.comptimePrint(
                "missing argument '{s}' for component '{s}'",
                .{ field.name, call.name },
            ));
        }
    }
    return bindings;
}

fn parameterCount(comptime parameters: anytype) usize {
    return switch (@typeInfo(@TypeOf(parameters))) {
        .@"struct" => |structure| structure.fields.len,
        else => 0,
    };
}

fn findParameter(comptime fields: anytype, comptime name: []const u8) ?usize {
    inline for (fields, 0..) |field, index| {
        if (comptime std.mem.eql(u8, field.name, name)) return index;
    }
    return null;
}

fn bindParameters(
    writer: *std.Io.Writer,
    comptime child: anytype,
    comptime parameters: anytype,
    comptime call: anytype,
    comptime bindings: anytype,
    comptime index: usize,
    parent: anytype,
    scope: anytype,
) !void {
    const fields = @typeInfo(@TypeOf(parameters)).@"struct".fields;
    if (index == fields.len) {
        try child.render(writer, scope);
        return;
    }

    const argument = call.args[bindings[index]];
    switch (argument.value) {
        .path => |path_source| {
            const path = comptime parser.parsePath(path_source, path_source.len);
            try bindValue(writer, child, parameters, call, bindings, index, parent, scope, expression.resolvePath(path, parent));
        },
        .string => |value| try bindValue(writer, child, parameters, call, bindings, index, parent, scope, value),
        .boolean => |value| try bindValue(writer, child, parameters, call, bindings, index, parent, scope, value),
        .integer => |value| try bindValue(writer, child, parameters, call, bindings, index, parent, scope, value),
    }
}

fn bindValue(
    writer: *std.Io.Writer,
    comptime child: anytype,
    comptime parameters: anytype,
    comptime call: anytype,
    comptime bindings: anytype,
    comptime index: usize,
    parent: anytype,
    scope: anytype,
    value: anytype,
) !void {
    const fields = @typeInfo(@TypeOf(parameters)).@"struct".fields;
    const Scoped = expression.Scope(@TypeOf(scope), fields[index].name, @TypeOf(value));
    const scoped: Scoped = .{ .outer = scope, .value = value };
    try bindParameters(writer, child, parameters, call, bindings, index + 1, parent, scoped);
}
