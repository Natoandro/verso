const std = @import("std");
const escape = @import("escape.zig");
const expression = @import("expression.zig");

pub fn writePath(writer: *std.Io.Writer, comptime path: anytype, context: anytype, comptime escaped: bool) !void {
    const Value = expression.resolvePathType(@TypeOf(context), path, 0);
    escape.ensureScalar(Value);
    try escape.write(writer, expression.resolvePath(path, context), escaped);
}

pub fn renderNodes(writer: *std.Io.Writer, comptime nodes: anytype, comptime count: usize, context: anytype) !void {
    try renderRange(writer, nodes, 0, count, context);
}

fn renderRange(
    writer: *std.Io.Writer,
    comptime nodes: anytype,
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
                try renderIf(writer, nodes, block, context);
                index = block.node_end - 1;
            },
            .for_block => |block| {
                try renderFor(writer, nodes, block, context);
                index = block.node_end - 1;
            },
        }
    }
}

fn renderIf(writer: *std.Io.Writer, comptime nodes: anytype, comptime block: anytype, context: anytype) !void {
    const Condition = expression.resolvePathType(@TypeOf(context), block.condition, 0);
    ensureCondition(Condition);
    const value = expression.resolvePath(block.condition, context);

    switch (@typeInfo(Condition)) {
        .bool => {
            if (block.capture != null) @compileError("if captures require an optional condition");
            if (value) {
                try renderRange(writer, nodes, block.body_start, block.body_end, context);
            } else {
                try renderElse(writer, nodes, block, context);
            }
        },
        .optional => |optional| {
            if (value) |unwrapped| {
                if (block.capture) |name| {
                    const Scoped = expression.Scope(@TypeOf(context), name, optional.child);
                    const scoped: Scoped = .{ .outer = context, .value = unwrapped };
                    try renderRange(writer, nodes, block.body_start, block.body_end, scoped);
                } else {
                    try renderRange(writer, nodes, block.body_start, block.body_end, context);
                }
            } else {
                try renderElse(writer, nodes, block, context);
            }
        },
        else => unreachable,
    }
}

fn renderElse(writer: *std.Io.Writer, comptime nodes: anytype, comptime block: anytype, context: anytype) !void {
    if (block.else_end > block.else_start) {
        try renderRange(writer, nodes, block.else_start, block.else_end, context);
    }
}

fn renderFor(writer: *std.Io.Writer, comptime nodes: anytype, comptime block: anytype, context: anytype) !void {
    const Collection = expression.resolvePathType(@TypeOf(context), block.iterable, 0);
    const Element = ensureIteration(Collection);
    const collection = expression.resolvePath(block.iterable, context);
    const Scoped = expression.Scope(@TypeOf(context), block.capture, Element);

    switch (@typeInfo(Collection)) {
        .array, .pointer => {
            for (collection) |item| {
                const scoped: Scoped = .{ .outer = context, .value = item };
                try renderRange(writer, nodes, block.body_start, block.body_end, scoped);
            }
        },
        else => unreachable,
    }
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
