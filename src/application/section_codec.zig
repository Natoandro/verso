const std = @import("std");
const section_domain = @import("../domain/sections.zig");

pub fn encode(allocator: std.mem.Allocator, payload: section_domain.Payload) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    switch (payload) {
        .text => |text| try output.writer.print("{f}", .{std.json.fmt(text, .{})}),
        .image => |image| {
            const json = struct {
                asset: []const u8,
                alt: []const u8,
                caption: ?[]const u8,
                display: ?[]const u8,
            }{
                .asset = image.asset,
                .alt = image.alt,
                .caption = image.caption,
                .display = if (image.display) |display| display.text() else null,
            };
            try output.writer.print("{f}", .{std.json.fmt(json, .{})});
        },
    }
    return output.toOwnedSlice();
}

pub fn decode(
    allocator: std.mem.Allocator,
    kind: []const u8,
    data: []const u8,
) !section_domain.Payload {
    const section_kind = section_domain.SectionKind.parse(kind) catch return error.InvalidStoredSection;
    return switch (section_kind) {
        .text => {
            const parsed = std.json.parseFromSliceLeaky(
                struct { markdown: []const u8 },
                allocator,
                data,
                .{},
            ) catch |failure| switch (failure) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidStoredSection,
            };
            const payload = section_domain.Payload{ .text = .{ .markdown = parsed.markdown } };
            section_domain.validatePayload(payload) catch return error.InvalidStoredSection;
            return payload;
        },
        .image => {
            const parsed = std.json.parseFromSliceLeaky(
                struct {
                    asset: []const u8,
                    alt: []const u8,
                    caption: ?[]const u8 = null,
                    display: ?[]const u8 = null,
                },
                allocator,
                data,
                .{},
            ) catch |failure| switch (failure) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidStoredSection,
            };
            const display = if (parsed.display) |value|
                section_domain.ImageDisplay.parse(value) catch return error.InvalidStoredSection
            else
                null;
            const payload = section_domain.Payload{ .image = .{
                .asset = parsed.asset,
                .alt = parsed.alt,
                .caption = parsed.caption,
                .display = display,
            } };
            section_domain.validatePayload(payload) catch return error.InvalidStoredSection;
            return payload;
        },
    };
}
