const std = @import("std");
const sections = @import("sections.zig");

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
    subject_ids: []const i64 = &.{},
    series_id: ?i64 = null,
    series_position: ?u32 = null,
    markdown: []const u8,
};

pub const Draft = struct {
    document_id: i64,
    version_id: i64,
    section_id: i64,
    version_number: u32,
    state: DraftState,
};

pub const CreateNextVersion = struct {
    source_version_id: i64,
};

pub const NextVersion = struct {
    document_id: i64,
    version_id: i64,
    version_number: u32,
    based_on_version_id: i64,
    state: DraftState,
};

pub const DraftSection = struct {
    id: ?i64 = null,
    payload: sections.Payload,
};

pub const SaveDraft = struct {
    document_id: i64,
    version_id: i64,
    expected_revision: u64,
    document_type: DocumentType,
    title: []const u8,
    slug: []const u8,
    description: ?[]const u8 = null,
    language: []const u8 = "en",
    subject_ids: []const i64 = &.{},
    series_id: ?i64 = null,
    series_position: ?u32 = null,
    sections: []const DraftSection,
};

pub const DraftDocument = struct {
    document_id: i64,
    version_id: i64,
    version_number: u32,
    revision_number: u64,
    document_type: DocumentType,
    title: []const u8,
    slug: []const u8,
    description: ?[]const u8,
    language: []const u8,
    subject_ids: []i64 = &.{},
    series_id: ?i64 = null,
    series_position: ?u32 = null,
    sections: []DraftSection,
};

pub const SaveResult = struct {
    version_id: i64,
    revision_number: u64,
};

pub fn validateCreateDraft(request: CreateDraft) !void {
    if (request.document_id) |document_id| {
        if (document_id <= 0) return error.InvalidDocumentId;
    }
    try validateMetadata(
        request.document_type,
        request.title,
        request.slug,
        request.description,
        request.language,
        request.subject_ids,
        request.series_id,
        request.series_position,
    );
    if (std.mem.indexOfScalar(u8, request.markdown, 0) != null) return error.InvalidMarkdown;
}

pub fn validateCreateNextVersion(request: CreateNextVersion) !void {
    if (request.source_version_id <= 0) return error.InvalidVersionId;
}

pub fn validateSaveDraft(request: SaveDraft) !void {
    if (request.document_id <= 0) return error.InvalidDocumentId;
    if (request.version_id <= 0) return error.InvalidVersionId;
    try validateMetadata(
        request.document_type,
        request.title,
        request.slug,
        request.description,
        request.language,
        request.subject_ids,
        request.series_id,
        request.series_position,
    );

    for (request.sections, 0..) |section, index| {
        if (section.id) |section_id| {
            if (section_id <= 0) return error.InvalidSectionId;
            for (request.sections[0..index]) |previous| {
                if (previous.id) |previous_id| {
                    if (previous_id == section_id) return error.DuplicateSectionId;
                }
            }
        }
        try sections.validatePayload(section.payload);
    }
}

fn validateMetadata(
    document_type: DocumentType,
    title: []const u8,
    slug: []const u8,
    description: ?[]const u8,
    language: []const u8,
    subject_ids: []const i64,
    series_id: ?i64,
    series_position: ?u32,
) !void {
    _ = document_type;
    if (!isValidText(title, false)) return error.InvalidTitle;
    if (!isValidSlug(slug)) return error.InvalidSlug;
    if (!isNonEmptyToken(language)) return error.InvalidLanguage;
    if (description) |value| {
        if (value.len != 0 and !isValidText(value, true)) return error.InvalidDescription;
    }
    for (subject_ids, 0..) |subject_id, index| {
        if (subject_id <= 0) return error.InvalidSubjectId;
        for (subject_ids[0..index]) |previous| {
            if (subject_id == previous) return error.DuplicateSubjectId;
        }
    }
    if ((series_id == null) != (series_position == null)) return error.InvalidSeriesMetadata;
    if (series_id) |id| {
        if (id <= 0) return error.InvalidSeriesId;
    }
    if (series_position) |position| {
        if (position == 0) return error.InvalidSeriesPosition;
    }
}

fn isValidText(value: []const u8, allow_newlines: bool) bool {
    if (value.len == 0 or std.mem.trim(u8, value, &std.ascii.whitespace).len == 0) {
        return false;
    }
    for (value) |character| {
        if (character == 0 or character == 0x7f) return false;
        if (character < 0x20 and !(allow_newlines and (character == '\n' or character == '\r' or character == '\t'))) {
            return false;
        }
    }
    return true;
}

fn isNonEmptyToken(value: []const u8) bool {
    if (!isValidText(value, false)) return false;
    for (value) |character| {
        if (!(std.ascii.isAlphanumeric(character) or character == '-' or character == '_')) return false;
    }
    return true;
}

fn isValidSlug(value: []const u8) bool {
    if (!isValidText(value, false)) return false;
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

    invalid = valid;
    invalid.title = "A\nTitle";
    try std.testing.expectError(error.InvalidTitle, validateCreateDraft(invalid));

    invalid = valid;
    invalid.series_position = 1;
    try std.testing.expectError(error.InvalidSeriesMetadata, validateCreateDraft(invalid));

    invalid = valid;
    invalid.subject_ids = &.{ 4, 4 };
    try std.testing.expectError(error.DuplicateSubjectId, validateCreateDraft(invalid));
}
