const std = @import("std");
const expression = @import("expression.zig");
const parser = @import("parser.zig");
const diagnostics = @import("diagnostics.zig");

const EmptyContext = struct {};

pub fn renderRegisteredComponent(
    writer: *std.Io.Writer,
    comptime child: anytype,
    comptime call: anytype,
    context: anytype,
) !void {
    if (!@inComptime()) {
        diagnostics.log(
            "component={s} enter writer=0x{x} context_type={s} context_size={d}",
            .{ call.name, @intFromPtr(writer), @typeName(@TypeOf(context)), @sizeOf(@TypeOf(context)) },
        );
    }
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
    if (!@inComptime()) {
        diagnostics.log(
            "component={s} bind index={d}/{d} writer=0x{x} parent_type={s} parent_size={d} scope_type={s} scope_size={d}",
            .{
                call.name,
                index,
                fields.len,
                @intFromPtr(writer),
                @typeName(@TypeOf(parent)),
                @sizeOf(@TypeOf(parent)),
                @typeName(@TypeOf(scope)),
                @sizeOf(@TypeOf(scope)),
            },
        );
    }
    if (index == fields.len) {
        if (!@inComptime()) {
            diagnostics.log(
                "component={s} child.render writer=0x{x} scope_addr=0x{x} scope_type={s} scope_size={d}",
                .{ call.name, @intFromPtr(writer), @intFromPtr(&scope), @typeName(@TypeOf(scope)), @sizeOf(@TypeOf(scope)) },
            );
        }
        try child.render(writer, scope);
        return;
    }

    const argument = call.args[bindings[index]];
    switch (argument.value) {
        .path => |path_source| {
            const path = comptime parser.parsePath(path_source, @import("ast.zig").max_path_segments);
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
    const scoped: Scoped = .{ .outer = &scope, .value = value };
    if (!@inComptime()) {
        diagnostics.log(
            "component={s} value index={d} value_type={s} scope_addr=0x{x} new_scope_addr=0x{x} outer_addr=0x{x} new_scope_size={d}",
            .{
                call.name,
                index,
                @typeName(@TypeOf(value)),
                @intFromPtr(&scope),
                @intFromPtr(&scoped),
                @intFromPtr(scoped.outer),
                @sizeOf(Scoped),
            },
        );
    }
    try bindParameters(writer, child, parameters, call, bindings, index + 1, parent, scoped);
}
