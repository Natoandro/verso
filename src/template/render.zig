const std = @import("std");
const escape = @import("escape.zig");
const expression = @import("expression.zig");
const parser = @import("parser.zig");

pub fn writePath(writer: *std.Io.Writer, comptime path: anytype, context: anytype, comptime escaped: bool) !void {
    const Value = expression.resolvePathType(@TypeOf(context), path, 0);
    escape.ensureScalar(Value);
    try escape.write(writer, expression.resolvePath(path, context), escaped);
}

pub fn renderNodes(
    writer: *std.Io.Writer,
    comptime nodes: anytype,
    comptime count: usize,
    comptime components: anytype,
    context: anytype,
) !void {
    try renderRange(writer, nodes, components, 0, count, context);
}

fn renderRange(
    writer: *std.Io.Writer,
    comptime nodes: anytype,
    comptime components: anytype,
    comptime start: usize,
    comptime end: usize,
    context: anytype,
) !void {
    comptime var index = start;
    inline while (index < end) : (index += 1) {
        switch (nodes[index]) {
            .text => |text| try writer.writeAll(text),
            .expression => |path| try writePath(writer, path, context, true),
            .raw_expression => |path| try writePath(writer, path, context, false),
            .if_block => |block| {
                try renderIf(writer, nodes, components, block, context);
                index = block.node_end - 1;
            },
            .for_block => |block| {
                try renderFor(writer, nodes, components, block, context);
                index = block.node_end - 1;
            },
            .component => |call| try renderComponent(writer, nodes, components, call, context),
        }
    }
}

fn renderIf(
    writer: *std.Io.Writer,
    comptime nodes: anytype,
    comptime components: anytype,
    comptime block: anytype,
    context: anytype,
) !void {
    const Condition = expression.resolvePathType(@TypeOf(context), block.condition, 0);
    ensureCondition(Condition);
    const value = expression.resolvePath(block.condition, context);

    switch (@typeInfo(Condition)) {
        .bool => {
            if (block.capture != null) @compileError("if captures require an optional condition");
            if (value) {
                try renderRange(writer, nodes, components, block.body_start, block.body_end, context);
            } else {
                try renderElse(writer, nodes, components, block, context);
            }
        },
        .optional => |optional| {
            if (value) |unwrapped| {
                if (block.capture) |name| {
                    const Scoped = expression.Scope(@TypeOf(context), name, optional.child);
                    const scoped: Scoped = .{ .outer = context, .value = unwrapped };
                    try renderRange(writer, nodes, components, block.body_start, block.body_end, scoped);
                } else {
                    try renderRange(writer, nodes, components, block.body_start, block.body_end, context);
                }
            } else {
                try renderElse(writer, nodes, components, block, context);
            }
        },
        else => unreachable,
    }
}

fn renderElse(
    writer: *std.Io.Writer,
    comptime nodes: anytype,
    comptime components: anytype,
    comptime block: anytype,
    context: anytype,
) !void {
    if (block.else_end > block.else_start) {
        try renderRange(writer, nodes, components, block.else_start, block.else_end, context);
    }
}

fn renderFor(
    writer: *std.Io.Writer,
    comptime nodes: anytype,
    comptime components: anytype,
    comptime block: anytype,
    context: anytype,
) !void {
    const Collection = expression.resolvePathType(@TypeOf(context), block.iterable, 0);
    const Element = ensureIteration(Collection);
    const collection = expression.resolvePath(block.iterable, context);
    const Scoped = expression.Scope(@TypeOf(context), block.capture, Element);

    switch (@typeInfo(Collection)) {
        .array, .pointer => {
            for (collection) |item| {
                const scoped: Scoped = .{ .outer = context, .value = item };
                try renderRange(writer, nodes, components, block.body_start, block.body_end, scoped);
            }
        },
        else => unreachable,
    }
}

fn renderComponent(
    writer: *std.Io.Writer,
    comptime nodes: anytype,
    comptime components: anytype,
    comptime call: anytype,
    context: anytype,
) !void {
    const Components = @TypeOf(components);
    const fields = switch (@typeInfo(Components)) {
        .@"struct" => |structure| structure.fields,
        else => @compileError("template components must be a struct"),
    };
    comptime var found = false;
    inline for (fields) |field| {
        if (comptime std.mem.eql(u8, field.name, call.name)) {
            found = true;
            const child = @field(components, field.name);
            try renderRegisteredComponent(writer, child, call, context);
        }
    }
    if (comptime !found) {
        @compileError(std.fmt.comptimePrint("unknown template component '{s}'", .{call.name}));
    }
    _ = nodes;
}

fn renderRegisteredComponent(writer: *std.Io.Writer, comptime child: anytype, comptime call: anytype, context: anytype) !void {
    const Options = @TypeOf(@TypeOf(child).template_options);
    if (comptime @hasField(Options, "parameters")) {
        const parameters = @TypeOf(child).template_options.parameters;
        const bindings = comptime validateComponentArguments(call, parameters);
        const base: struct {} = .{};
        try bindComponentParameters(writer, child, parameters, call, bindings, 0, context, base);
    } else {
        if (call.count != 0) @compileError("component does not declare parameters");
        try child.render(writer, .{});
    }
}

fn validateComponentArguments(comptime call: anytype, comptime parameters: anytype) [parameterCount(parameters)]usize {
    const ParameterType = @TypeOf(parameters);
    const fields = switch (@typeInfo(ParameterType)) {
        .@"struct" => |structure| structure.fields,
        else => @compileError("component parameters must be a struct"),
    };
    comptime var bindings: [fields.len]usize = undefined;
    comptime var bound: [fields.len]bool = [_]bool{false} ** fields.len;

    inline for (call.args[0..call.count], 0..) |argument, argument_index| {
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

fn bindComponentParameters(
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
            try bindComponentValue(
                writer,
                child,
                parameters,
                call,
                bindings,
                index,
                parent,
                scope,
                expression.resolvePath(path, parent),
            );
        },
        .string => |value| try bindComponentValue(writer, child, parameters, call, bindings, index, parent, scope, value),
        .boolean => |value| try bindComponentValue(writer, child, parameters, call, bindings, index, parent, scope, value),
        .integer => |value| try bindComponentValue(writer, child, parameters, call, bindings, index, parent, scope, value),
    }
}

fn bindComponentValue(
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
    try bindComponentParameters(writer, child, parameters, call, bindings, index + 1, parent, scoped);
}

fn ensureCondition(comptime Value: type) void {
    switch (@typeInfo(Value)) {
        .bool, .optional => {},
        else => @compileError(std.fmt.comptimePrint(
            "template if condition must be bool or optional, got {s}",
            .{@typeName(Value)},
        )),
    }
}

fn ensureIteration(comptime Value: type) type {
    return switch (@typeInfo(Value)) {
        .array => |array| array.child,
        .pointer => |pointer| if (pointer.size == .slice)
            pointer.child
        else
            @compileError(std.fmt.comptimePrint(
                "template for requires an array or slice, got {s}",
                .{@typeName(Value)},
            )),
        else => @compileError(std.fmt.comptimePrint(
            "template for requires an array or slice, got {s}",
            .{@typeName(Value)},
        )),
    };
}
