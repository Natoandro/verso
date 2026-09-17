const std = @import("std");

pub const DocumentType = enum {
    article,

    pub fn parse(value: []const u8) error{InvalidDocumentType}!DocumentType {
        return std.meta.stringToEnum(DocumentType, value) orelse error.InvalidDocumentType;
    }

    pub fn text(self: DocumentType) []const u8 {
        return @tagName(self);
    }
};

pub const DraftState = enum {
    draft,

    pub fn text(self: DraftState) []const u8 {
        return @tagName(self);
    }
};

pub const CreateDraft = struct {
    document_id: ?i64 = null,
    document_type: DocumentType,
    title: []const u8,
    slug: []const u8,
    description: ?[]const u8 = null,
    language: []const u8 = "en",
    markdown: []const u8,
};

pub const Draft = struct {
    document_id: i64,
    version_id: i64,
    section_id: i64,
    version_number: u32,
    state: DraftState,
};

pub fn validateCreateDraft(request: CreateDraft) !void {
    if (request.document_id) |document_id| {
        if (document_id <= 0) return error.InvalidDocumentId;
    }
    if (!isNonEmptyText(request.title)) return error.InvalidTitle;
    if (!isValidSlug(request.slug)) return error.InvalidSlug;
    if (!isNonEmptyToken(request.language)) return error.InvalidLanguage;
    if (request.description) |description| {
        if (std.mem.indexOfScalar(u8, description, 0) != null) return error.InvalidDescription;
    }
    if (std.mem.indexOfScalar(u8, request.markdown, 0) != null) return error.InvalidMarkdown;
}

fn isNonEmptyText(value: []const u8) bool {
    return std.mem.trim(u8, value, &std.ascii.whitespace).len > 0 and
        std.mem.indexOfScalar(u8, value, 0) == null;
}

fn isNonEmptyToken(value: []const u8) bool {
    if (!isNonEmptyText(value)) return false;
    for (value) |character| {
        if (!(std.ascii.isAlphanumeric(character) or character == '-' or character == '_')) return false;
    }
    return true;
}

fn isValidSlug(value: []const u8) bool {
    if (!isNonEmptyText(value)) return false;
    for (value) |character| {
        if (!(std.ascii.isAlphanumeric(character) or character == '-' or character == '_')) return false;
    }
    return true;
}

test "document type parsing is allowlisted" {
    try std.testing.expectEqual(DocumentType.article, try DocumentType.parse("article"));
    try std.testing.expectError(error.InvalidDocumentType, DocumentType.parse("book"));
}

test "draft metadata validation rejects invalid values" {
    const valid = CreateDraft{
        .document_type = .article,
        .title = "A title",
        .slug = "a-title",
        .markdown = "# Hello",
    };
    try validateCreateDraft(valid);
    var invalid = valid;
    invalid.title = " ";
    try std.testing.expectError(error.InvalidTitle, validateCreateDraft(invalid));
}
