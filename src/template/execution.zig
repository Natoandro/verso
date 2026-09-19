const std = @import("std");

// Each operation is generated at comptime for one validated AST node and one
// lexical context type. The erased context pointer is only the dispatch
// boundary; the operation immediately casts it back to that exact type before
// handing it to the semantic renderer. This keeps field access typed while
// preventing a large template from becoming one giant inline-expanded
// function.
const Operation = *const fn (*std.Io.Writer, *const anyopaque, *usize) anyerror!void;

pub fn renderRange(
    writer: *std.Io.Writer,
    comptime nodes: anytype,
    comptime components: anytype,
    comptime start: usize,
    comptime end: usize,
    comptime Renderer: type,
    context: anytype,
) !void {
    const Plan = comptime RangePlan(nodes, components, start, end, Renderer, @TypeOf(context));
    var current_context = context;
    const raw_context: *const anyopaque = @ptrCast(&current_context);
    var index: usize = 0;
    while (index < Plan.operations.len) : (index += 1) {
        try Plan.operations[index](writer, raw_context, &index);
    }
}

fn RangePlan(
    comptime nodes: anytype,
    comptime components: anytype,
    comptime start: usize,
    comptime end: usize,
    comptime Renderer: type,
    comptime Context: type,
) type {
    return struct {
        // A declaration-level constant keeps the operation table out of each
        // renderRange stack frame. It is generated once for this typed range.
        pub const operations = buildOperations(nodes, components, start, end, Renderer, Context);
    };
}

fn buildOperations(
    comptime nodes: anytype,
    comptime components: anytype,
    comptime start: usize,
    comptime end: usize,
    comptime Renderer: type,
    comptime Context: type,
) [operationCount(nodes, start, end)]Operation {
    @setEvalBranchQuota(10_000 + (end - start) * 10);
    var operations: [operationCount(nodes, start, end)]Operation = undefined;
    comptime var node_index = start;
    comptime var operation_index = 0;
    inline while (node_index < end) : (operation_index += 1) {
        const node = nodes[node_index];
        operations[operation_index] = operationFor(Context, nodes, components, Renderer, node, start);
        node_index = switch (node) {
            .if_block => |block| block.node_end,
            .for_block => |block| block.node_end,
            .snippet_declaration => |snippet| snippet.node_end,
            else => node_index + 1,
        };
    }
    return operations;
}

fn operationCount(comptime nodes: anytype, comptime start: usize, comptime end: usize) usize {
    @setEvalBranchQuota(10_000 + (end - start) * 10);
    comptime var node_index = start;
    comptime var count: usize = 0;
    inline while (node_index < end) : (count += 1) {
        node_index = switch (nodes[node_index]) {
            .if_block => |block| block.node_end,
            .for_block => |block| block.node_end,
            .snippet_declaration => |snippet| snippet.node_end,
            else => node_index + 1,
        };
    }
    return count;
}

fn operationFor(
    comptime Context: type,
    comptime nodes: anytype,
    comptime components: anytype,
    comptime Renderer: type,
    comptime node: anytype,
    comptime range_start: usize,
) Operation {
    const Adapter = struct {
        fn run(writer: *std.Io.Writer, raw_context: *const anyopaque, index: *usize) anyerror!void {
            const typed_context: *const Context = @ptrCast(@alignCast(raw_context));
            const context = typed_context.*;

            switch (node) {
                .text => |text| try writer.writeAll(text),
                .expression => |path| try Renderer.write_path(writer, path, context, true),
                .raw_expression => |path| try Renderer.write_path(writer, path, context, false),
                .if_block => |block| {
                    try Renderer.if_block(writer, nodes, components, block, context);
                    index.* = operationCount(nodes, range_start, block.node_end) - 1;
                },
                .for_block => |block| {
                    try Renderer.for_block(writer, nodes, components, block, context);
                    index.* = operationCount(nodes, range_start, block.node_end) - 1;
                },
                .component => |call| try Renderer.component(writer, nodes, components, call, context),
                .snippet_declaration => |snippet| index.* = operationCount(nodes, range_start, snippet.node_end) - 1,
            }
        }
    };
    return Adapter.run;
}
