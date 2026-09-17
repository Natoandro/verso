const std = @import("std");

pub const SectionKind = enum {
    text,
    image,

    pub fn parse(value: []const u8) error{InvalidSectionKind}!SectionKind {
        return std.meta.stringToEnum(SectionKind, value) orelse error.InvalidSectionKind;
    }

    pub fn name(self: SectionKind) []const u8 {
        return @tagName(self);
    }
};

pub const ImageDisplay = enum {
    inline_display,
    wide,
    full,

    pub fn parse(value: []const u8) error{InvalidImageDisplay}!ImageDisplay {
        if (std.mem.eql(u8, value, "inline")) return .inline_display;
        return std.meta.stringToEnum(ImageDisplay, value) orelse error.InvalidImageDisplay;
    }

    pub fn text(self: ImageDisplay) []const u8 {
        return switch (self) {
            .inline_display => "inline",
            .wide => "wide",
            .full => "full",
        };
    }
};

pub const Text = struct {
    markdown: []const u8,
};

pub const Image = struct {
    asset: []const u8,
    alt: []const u8,
    caption: ?[]const u8 = null,
    display: ?ImageDisplay = null,
};

pub const Payload = union(SectionKind) {
    text: Text,
    image: Image,

    pub fn kind(self: Payload) SectionKind {
        return self;
    }
};

pub const Insert = struct {
    version_id: i64,
    position: u32,
    expected_revision: u64,
    payload: Payload,
};

pub const Update = struct {
    version_id: i64,
    section_id: i64,
    expected_revision: u64,
    payload: Payload,
};

pub const Move = struct {
    version_id: i64,
    section_id: i64,
    position: u32,
    expected_revision: u64,
};

pub const Duplicate = struct {
    version_id: i64,
    section_id: i64,
    position: u32,
    expected_revision: u64,
};

pub const Delete = struct {
    version_id: i64,
    section_id: i64,
    expected_revision: u64,
};

pub fn validateInsert(request: Insert) !void {
    try validateVersionId(request.version_id);
    try validatePayload(request.payload);
}

pub fn validateUpdate(request: Update) !void {
    try validateVersionId(request.version_id);
    try validateSectionId(request.section_id);
    try validatePayload(request.payload);
}

pub fn validateMove(request: Move) !void {
    try validateVersionId(request.version_id);
    try validateSectionId(request.section_id);
}

pub fn validateDuplicate(request: Duplicate) !void {
    try validateVersionId(request.version_id);
    try validateSectionId(request.section_id);
}

pub fn validateDelete(request: Delete) !void {
    try validateVersionId(request.version_id);
    try validateSectionId(request.section_id);
}

pub fn validatePayload(payload: Payload) !void {
    switch (payload) {
        .text => |text| {
            if (std.mem.indexOfScalar(u8, text.markdown, 0) != null) {
                return error.InvalidMarkdown;
            }
        },
        .image => |image| {
            if (!isValidAssetName(image.asset)) return error.InvalidAssetName;
            if (!isNonEmptyText(image.alt)) return error.InvalidAltText;
            if (image.caption) |caption| {
                if (std.mem.indexOfScalar(u8, caption, 0) != null) return error.InvalidCaption;
            }
        },
    }
}

fn validateVersionId(id: i64) !void {
    if (id <= 0) return error.InvalidVersionId;
}

fn validateSectionId(id: i64) !void {
    if (id <= 0) return error.InvalidSectionId;
}

fn isNonEmptyText(value: []const u8) bool {
    return std.mem.trim(u8, value, &std.ascii.whitespace).len > 0 and
        std.mem.indexOfScalar(u8, value, 0) == null;
}

fn isValidAssetName(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |character| {
        if (!(std.ascii.isAlphanumeric(character) or character == '.' or character == '_' or character == '-')) {
            return false;
        }
    }
    return true;
}

test "section payload validation covers text and image data" {
    try validatePayload(.{ .text = .{ .markdown = "# Hello" } });
    try std.testing.expectError(
        error.InvalidMarkdown,
        validatePayload(.{ .text = .{ .markdown = "bad\x00markdown" } }),
    );
    try validatePayload(.{ .image = .{ .asset = "diagram.png", .alt = "A diagram" } });
    try std.testing.expectError(
        error.InvalidAssetName,
        validatePayload(.{ .image = .{ .asset = "../diagram.png", .alt = "A diagram" } }),
    );
    try std.testing.expectError(
        error.InvalidAltText,
        validatePayload(.{ .image = .{ .asset = "diagram.png", .alt = " " } }),
    );
}
