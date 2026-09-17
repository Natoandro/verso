const std = @import("std");
const parser = @import("parser.zig");
const renderer = @import("render.zig");

const EmptyComponents = struct {};

pub fn Template(comptime source: []const u8, comptime options: anytype) type {
    return struct {
        pub const template_options = options;

        pub fn render(
            comptime self: @This(),
            writer: *std.Io.Writer,
            context: anytype,
        ) !void {
            _ = self;
            const parsed = comptime parser.parse(source);
            if (comptime @hasField(@TypeOf(options), "components")) {
                try renderer.renderNodes(writer, parsed.nodes, parsed.count, options.components, context);
            } else {
                try renderer.renderNodes(writer, parsed.nodes, parsed.count, EmptyComponents{}, context);
            }
        }
    };
}

pub fn parse(comptime source: []const u8, comptime options: anytype) Template(source, options) {
    comptime {
        const parsed = parser.parse(source);
        validateComponentNames(parsed, options);
    }
    return .{};
}

fn validateComponentNames(comptime parsed: anytype, comptime options: anytype) void {
    inline for (parsed.nodes[0..parsed.count]) |node| {
        switch (node) {
            .component => |call| {
                if (comptime call.local_decl == null and !hasRegisteredComponent(options, call.name)) {
                    @compileError(std.fmt.comptimePrint(
                        "unknown template component '{s}'",
                        .{call.name},
                    ));
                }
            },
            else => {},
        }
    }
}

fn hasRegisteredComponent(comptime options: anytype, comptime name: []const u8) bool {
    if (comptime !@hasField(@TypeOf(options), "components")) return false;
    const Components = @TypeOf(options.components);
    const fields = switch (@typeInfo(Components)) {
        .@"struct" => |structure| structure.fields,
        else => @compileError("template components must be a struct"),
    };
    inline for (fields) |field| {
        if (comptime std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}
