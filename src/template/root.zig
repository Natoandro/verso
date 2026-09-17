const std = @import("std");
const parser = @import("parser.zig");
const renderer = @import("render.zig");

pub fn Template(comptime source: []const u8) type {
    return struct {
        pub fn render(
            comptime self: @This(),
            writer: *std.Io.Writer,
            context: anytype,
        ) !void {
            _ = self;
            const parsed = comptime parser.parse(source);
            try renderer.renderNodes(writer, parsed.nodes, parsed.count, context);
        }
    };
}

pub fn parse(comptime source: []const u8) Template(source) {
    comptime {
        _ = parser.parse(source);
    }
    return .{};
}
