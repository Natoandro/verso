const std = @import("std");
const auth_identity = @import("../auth/identity.zig");

pub const AuditInterface = enum {
    web,
    mcp,
    cli,
    system,
};

pub const CreateAuthor = struct {
    display_name: []const u8,
    slug: []const u8,
    biography: ?[]const u8 = null,
    user_id: ?i64 = null,
};

pub const UpdateAuthor = struct {
    author_id: i64,
    display_name: []const u8,
    slug: []const u8,
    biography: ?[]const u8 = null,
};

pub const AssignmentScope = union(enum) {
    author: i64,
    document: i64,
};

pub const CreateAssignment = struct {
    editor_user_id: i64,
    scope: AssignmentScope,
};

pub const RevokeAssignment = struct {
    assignment_id: i64,
    expected_revision: i64,
};

pub const SetVersionAuthors = struct {
    version_id: i64,
    author_ids: []const i64,
    expected_revision: i64,
};

pub fn validateCreateAuthor(request: CreateAuthor) !void {
    try validateAuthorFields(request.display_name, request.slug, request.biography);
    if (request.user_id) |user_id| try validateId(user_id, error.InvalidAuthorUser);
}

pub fn validateUpdateAuthor(request: UpdateAuthor) !void {
    try validateId(request.author_id, error.InvalidAuthor);
    try validateAuthorFields(request.display_name, request.slug, request.biography);
}

pub fn validateCreateAssignment(request: CreateAssignment) !void {
    try validateId(request.editor_user_id, error.InvalidEditor);
    switch (request.scope) {
        .author, .document => |id| try validateId(id, error.InvalidAssignmentScope),
    }
}

pub fn validateRevokeAssignment(request: RevokeAssignment) !void {
    try validateId(request.assignment_id, error.InvalidAssignment);
    if (request.expected_revision < 0) return error.InvalidAssignmentRevision;
}

pub fn validateSetVersionAuthors(request: SetVersionAuthors) !void {
    try validateId(request.version_id, error.InvalidVersion);
    if (request.expected_revision < 0) return error.InvalidRevision;
    for (request.author_ids, 0..) |author_id, index| {
        try validateId(author_id, error.InvalidAuthor);
        for (request.author_ids[0..index]) |previous| {
            if (previous == author_id) return error.DuplicateAuthor;
        }
    }
}

fn validateAuthorFields(
    display_name: []const u8,
    slug: []const u8,
    biography: ?[]const u8,
) !void {
    try auth_identity.validateDisplayName(display_name);
    try validateSlug(slug);
    if (biography) |text| {
        if (text.len > 100_000) return error.InvalidBiography;
        for (text) |character| {
            if (character == 0 or character == 0x7f or
                (character < 0x20 and character != '\n' and character != '\r' and character != '\t'))
            {
                return error.InvalidBiography;
            }
        }
    }
}

fn validateSlug(slug: []const u8) !void {
    if (slug.len == 0 or slug.len > 128 or !std.mem.eql(u8, slug, std.mem.trim(u8, slug, &std.ascii.whitespace))) {
        return error.InvalidAuthorSlug;
    }
    for (slug) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') {
            return error.InvalidAuthorSlug;
        }
    }
}

fn validateId(id: i64, invalid_error: anyerror) !void {
    if (id <= 0) return invalid_error;
}

test "author and assignment requests reject malformed values" {
    try std.testing.expectError(error.InvalidAuthorSlug, validateCreateAuthor(.{
        .display_name = "Author",
        .slug = "not a slug",
    }));
    try std.testing.expectError(error.InvalidBiography, validateCreateAuthor(.{
        .display_name = "Author",
        .slug = "author",
        .biography = "bad\x00text",
    }));
    try std.testing.expectError(error.InvalidAssignmentScope, validateCreateAssignment(.{
        .editor_user_id = 2,
        .scope = .{ .document = 0 },
    }));
    try std.testing.expectError(error.InvalidAssignmentRevision, validateRevokeAssignment(.{
        .assignment_id = 1,
        .expected_revision = -1,
    }));
    const author_ids = [_]i64{ 2, 2 };
    try std.testing.expectError(error.DuplicateAuthor, validateSetVersionAuthors(.{
        .version_id = 1,
        .author_ids = &author_ids,
        .expected_revision = 0,
    }));
}
