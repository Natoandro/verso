const std = @import("std");
const parser = @import("parser.zig");
const renderer = @import("render.zig");

pub const escape = @import("escape.zig");

const EmptyComponents = struct {};

pub fn Layout(comptime source: []const u8) type {
    return struct {
        pub fn with(comptime self: @This(), comptime slots: anytype) Template(source, .{ .components = slots }) {
            _ = self;
            comptime {
                const parsed = parser.parse(source);
                validateComponentNames(parsed, .{ .components = slots });
            }
            return .{};
        }
    };
}

pub fn layout(comptime source: []const u8) Layout(source) {
    comptime _ = parser.parse(source);
    return .{};
}

pub fn Template(comptime source: []const u8, comptime options: anytype) type {
    return struct {
        pub const template_options = options;
        pub const parsed = parser.parse(source);

        pub fn render(
            comptime self: @This(),
            writer: *std.Io.Writer,
            context: anytype,
        ) !void {
            _ = self;
            // Pass the parsed value directly as a comptime argument. Keeping
            // the whole Parsed value in a runtime local would materialize its
            // source-sized node buffer in every render stack frame.
            if (comptime @hasField(@TypeOf(options), "components")) {
                try renderer.renderNodes(writer, parsed, options.components, context);
            } else {
                try renderer.renderNodes(writer, parsed, EmptyComponents{}, context);
            }
        }

        /// Collects the writer renderer's output for callers that need an
        /// owned response body. This is deliberately a thin convenience
        /// wrapper; templates still parse and validate at comptime and use
        /// the same streaming renderer.
        pub fn renderAlloc(
            comptime self: @This(),
            allocator: std.mem.Allocator,
            context: anytype,
        ) ![]u8 {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            try self.render(&output.writer, context);
            return output.toOwnedSlice();
        }
    };
}

pub fn parse(comptime source: []const u8, comptime options: anytype) Template(source, options) {
    const TemplateType = Template(source, options);
    comptime {
        validateComponentNames(TemplateType.parsed, options);
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
