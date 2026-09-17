const std = @import("std");
const escape = @import("escape.zig");
const expression = @import("expression.zig");
const parser = @import("parser.zig");
const component_renderer = @import("component_renderer.zig");

const EmptyContext = struct {};

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
            .snippet_declaration => |snippet| index = snippet.node_end - 1,
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
    if (comptime call.local_decl != null) {
        try renderLocalSnippet(writer, nodes, components, call, call.local_decl.?, context);
        return;
    }

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
            try component_renderer.renderRegisteredComponent(writer, child, call, context);
        }
    }
    if (comptime !found) {
        @compileError(std.fmt.comptimePrint("unknown template component '{s}'", .{call.name}));
    }
}

fn renderLocalSnippet(
    writer: *std.Io.Writer,
    comptime nodes: anytype,
    comptime components: anytype,
    comptime call: anytype,
    comptime declaration_index: usize,
    context: anytype,
) !void {
    const declaration = nodes[declaration_index].snippet_declaration;
    const bindings = comptime validateSnippetArguments(call, declaration);
    const base: EmptyContext = .{};
    try bindSnippetParameters(writer, nodes, components, declaration, call, bindings, 0, context, base);
}

fn validateSnippetArguments(comptime call: anytype, comptime declaration: anytype) [declaration.parameter_count]usize {
    comptime var bindings: [declaration.parameter_count]usize = undefined;
    if (call.count == 0) {
        if (declaration.parameter_count != 0) {
            @compileError(std.fmt.comptimePrint(
                "missing arguments for snippet '{s}'",
                .{declaration.name},
            ));
        }
        return bindings;
    }

    const positional = call.args[0].name.len == 0;
    inline for (call.args[0..call.count]) |argument| {
        if ((argument.name.len == 0) != positional) {
            @compileError(std.fmt.comptimePrint(
                "snippet '{s}' cannot mix positional and named arguments",
                .{declaration.name},
            ));
        }
    }

    if (positional) {
        if (call.count < declaration.parameter_count) {
            @compileError(std.fmt.comptimePrint(
                "missing arguments for snippet '{s}'",
                .{declaration.name},
            ));
        }
        if (call.count > declaration.parameter_count) {
            @compileError(std.fmt.comptimePrint(
                "too many arguments for snippet '{s}'",
                .{declaration.name},
            ));
        }
        inline for (call.args[0..call.count], 0..) |_, argument_index| {
            bindings[argument_index] = argument_index;
        }
    } else {
        comptime var bound: [declaration.parameter_count]bool = [_]bool{false} ** declaration.parameter_count;
        inline for (call.args[0..call.count], 0..) |argument, argument_index| {
            const parameter_index = findSnippetParameter(declaration.parameters, declaration.parameter_count, argument.name) orelse
                @compileError(std.fmt.comptimePrint(
                    "unknown argument '{s}' for snippet '{s}'",
                    .{ argument.name, declaration.name },
                ));
            if (bound[parameter_index]) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate argument '{s}' for snippet '{s}'",
                    .{ argument.name, declaration.name },
                ));
            }
            bound[parameter_index] = true;
            bindings[parameter_index] = argument_index;
        }
        inline for (declaration.parameters[0..declaration.parameter_count], 0..) |parameter, parameter_index| {
            if (!bound[parameter_index]) {
                @compileError(std.fmt.comptimePrint(
                    "missing argument '{s}' for snippet '{s}'",
                    .{ parameter, declaration.name },
                ));
            }
        }
    }
    return bindings;
}

fn findSnippetParameter(parameters: anytype, comptime count: usize, comptime name: []const u8) ?usize {
    inline for (parameters[0..count], 0..) |parameter, index| {
        if (comptime std.mem.eql(u8, parameter, name)) return index;
    }
    return null;
}

fn bindSnippetParameters(
    writer: *std.Io.Writer,
    comptime nodes: anytype,
    comptime components: anytype,
    comptime declaration: anytype,
    comptime call: anytype,
    comptime bindings: anytype,
    comptime index: usize,
    parent: anytype,
    scope: anytype,
) !void {
    if (index == declaration.parameter_count) {
        try renderRange(writer, nodes, components, declaration.body_start, declaration.body_end, scope);
        return;
    }

    const argument = call.args[bindings[index]];
    switch (argument.value) {
        .path => |path_source| {
            const path = comptime parser.parsePath(path_source, path_source.len);
            try bindSnippetValue(
                writer,
                nodes,
                components,
                declaration,
                call,
                bindings,
                index,
                parent,
                scope,
                expression.resolvePath(path, parent),
            );
        },
        .string => |value| try bindSnippetValue(writer, nodes, components, declaration, call, bindings, index, parent, scope, value),
        .boolean => |value| try bindSnippetValue(writer, nodes, components, declaration, call, bindings, index, parent, scope, value),
        .integer => |value| try bindSnippetValue(writer, nodes, components, declaration, call, bindings, index, parent, scope, value),
    }
}

fn bindSnippetValue(
    writer: *std.Io.Writer,
    comptime nodes: anytype,
    comptime components: anytype,
    comptime declaration: anytype,
    comptime call: anytype,
    comptime bindings: anytype,
    comptime index: usize,
    parent: anytype,
    scope: anytype,
    value: anytype,
) !void {
    const Scoped = expression.Scope(@TypeOf(scope), declaration.parameters[index], @TypeOf(value));
    const scoped: Scoped = .{ .outer = scope, .value = value };
    try bindSnippetParameters(writer, nodes, components, declaration, call, bindings, index + 1, parent, scoped);
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
