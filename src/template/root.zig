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
            inline for (parsed.nodes[0..parsed.count]) |node| {
                switch (node) {
                    .text => |text| try writer.writeAll(text),
                    .expression => |path| try renderer.writePath(writer, path, context, true),
                    .raw_expression => |path| try renderer.writePath(writer, path, context, false),
                }
            }
        }
    };
}

pub fn parse(comptime source: []const u8) Template(source) {
    comptime {
        _ = parser.parse(source);
    }
    return .{};
}
