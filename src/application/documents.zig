const std = @import("std");
const domain = @import("../domain/document.zig");
const section_domain = @import("../domain/sections.zig");
const storage = @import("../storage/documents.zig");
const section_storage = @import("../storage/sections.zig");

pub const Actor = enum {
    local_operator,
};

pub const LoadedDraft = struct {
    arena: std.heap.ArenaAllocator,
    document: domain.DraftDocument,

    pub fn deinit(self: *LoadedDraft) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    store: *storage.Store,

    pub fn init(allocator: std.mem.Allocator, store: *storage.Store) Service {
        return .{ .allocator = allocator, .store = store };
    }

    pub fn createDraft(
        self: *Service,
        actor: Actor,
        request: domain.CreateDraft,
    ) !domain.Draft {
        try authorizeCreateDraft(actor);
        try domain.validateCreateDraft(request);

        const section_data = try buildTextSection(self.allocator, request.markdown);
        defer self.allocator.free(section_data);
        return self.store.createDraft(request, section_data);
    }

    pub fn saveDraft(
        self: *Service,
        actor: Actor,
        request: domain.SaveDraft,
    ) !domain.SaveResult {
        try authorizeDraftMutation(actor);
        try domain.validateSaveDraft(request);

        const encoded = try self.allocator.alloc(storage.EncodedSection, request.sections.len);
        defer self.allocator.free(encoded);
        var encoded_count: usize = 0;
        defer for (encoded[0..encoded_count]) |section| self.allocator.free(section.data);

        for (request.sections, 0..) |section, index| {
            encoded[index] = .{
                .id = section.id,
                .kind = section.payload.kind().name(),
                .data = try encodeSection(self.allocator, section.payload),
            };
            encoded_count += 1;
        }
        return self.store.saveDraft(request, encoded);
    }

    pub fn loadDraft(self: *Service, actor: Actor, version_id: i64) !LoadedDraft {
        try authorizeDraftRead(actor);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        const record = try self.store.loadDraft(arena_allocator, version_id);
        const document_type = domain.DocumentType.parse(record.document_type) catch return error.InvalidStoredDocument;
        const version_number = std.math.cast(u32, record.version_number) orelse return error.InvalidStoredDocument;
        const revision_number = std.math.cast(u64, record.revision_number) orelse return error.InvalidStoredDocument;
        const sections = try arena_allocator.alloc(domain.DraftSection, record.sections.len);

        for (record.sections, 0..) |section, index| {
            const position = std.math.cast(usize, section.position) orelse return error.InvalidStoredDocument;
            if (position != index) return error.InvalidStoredDocument;
            sections[index] = .{
                .id = section.id,
                .payload = try decodeSection(arena_allocator, section.kind, section.data),
            };
        }

        return .{
            .arena = arena,
            .document = .{
                .document_id = record.document_id,
                .version_id = record.version_id,
                .version_number = version_number,
                .revision_number = revision_number,
                .document_type = document_type,
                .title = record.title,
                .slug = record.slug,
                .description = record.description,
                .language = record.language,
                .sections = sections,
            },
        };
    }

    pub fn insertSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Insert,
    ) !section_storage.MutationResult {
        try authorizeSectionMutation(actor);
        try section_domain.validateInsert(request);
        const data = try encodeSection(self.allocator, request.payload);
        defer self.allocator.free(data);
        return section_storage.insertSection(
            self.store,
            request.version_id,
            request.position,
            request.expected_revision,
            request.payload.kind().name(),
            data,
        );
    }

    pub fn updateSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Update,
    ) !section_storage.MutationResult {
        try authorizeSectionMutation(actor);
        try section_domain.validateUpdate(request);
        const data = try encodeSection(self.allocator, request.payload);
        defer self.allocator.free(data);
        return section_storage.updateSection(
            self.store,
            request.version_id,
            request.section_id,
            request.expected_revision,
            request.payload.kind().name(),
            data,
        );
    }

    pub fn moveSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Move,
    ) !section_storage.MutationResult {
        try authorizeSectionMutation(actor);
        try section_domain.validateMove(request);
        return section_storage.moveSection(
            self.store,
            request.version_id,
            request.section_id,
            request.position,
            request.expected_revision,
        );
    }

    pub fn duplicateSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Duplicate,
    ) !section_storage.MutationResult {
        try authorizeSectionMutation(actor);
        try section_domain.validateDuplicate(request);
        return section_storage.duplicateSection(
            self.store,
            request.version_id,
            request.section_id,
            request.position,
            request.expected_revision,
        );
    }

    pub fn deleteSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Delete,
    ) !section_storage.MutationResult {
        try authorizeSectionMutation(actor);
        try section_domain.validateDelete(request);
        return section_storage.deleteSection(
            self.store,
            request.version_id,
            request.section_id,
            request.expected_revision,
        );
    }
};

fn authorizeCreateDraft(actor: Actor) !void {
    return switch (actor) {
        .local_operator => {},
    };
}

fn authorizeSectionMutation(actor: Actor) !void {
    return switch (actor) {
        .local_operator => {},
    };
}

fn authorizeDraftMutation(actor: Actor) !void {
    return switch (actor) {
        .local_operator => {},
    };
}

fn authorizeDraftRead(actor: Actor) !void {
    return switch (actor) {
        .local_operator => {},
    };
}

fn buildTextSection(allocator: std.mem.Allocator, markdown: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.print("{f}", .{std.json.fmt(.{ .markdown = markdown }, .{})});
    return output.toOwnedSlice();
}

fn encodeSection(allocator: std.mem.Allocator, payload: section_domain.Payload) ![]u8 {
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

fn decodeSection(allocator: std.mem.Allocator, kind: []const u8, data: []const u8) !section_domain.Payload {
    const section_kind = section_domain.SectionKind.parse(kind) catch return error.InvalidStoredSection;
    return switch (section_kind) {
        .text => {
            const parsed = std.json.parseFromSliceLeaky(
                struct { markdown: []const u8 },
                allocator,
                data,
                .{},
            ) catch return error.InvalidStoredSection;
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
            ) catch return error.InvalidStoredSection;
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
