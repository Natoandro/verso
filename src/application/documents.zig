const std = @import("std");
const domain = @import("../domain/document.zig");
const section_domain = @import("../domain/sections.zig");
const storage = @import("../storage/documents.zig");
const version_storage = @import("../storage/document_versions.zig");
const section_storage = @import("../storage/sections.zig");
const identity_application = @import("identity.zig");
const document_access = @import("document_access.zig");

pub const Actor = union(enum) {
    local_operator,
    user: i64,
};

pub const LoadedDraft = struct {
    arena: ?std.heap.ArenaAllocator,
    document: domain.DraftDocument,

    pub fn deinit(self: *LoadedDraft) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = undefined;
    }
};

pub const DraftSummary = storage.DraftSummary;

pub const Service = struct {
    allocator: std.mem.Allocator,
    store: *storage.Store,
    identity_service: ?*identity_application.Service,

    pub fn init(allocator: std.mem.Allocator, store: *storage.Store) Service {
        return .{ .allocator = allocator, .store = store, .identity_service = null };
    }

    pub fn initProtected(
        allocator: std.mem.Allocator,
        store: *storage.Store,
        identity_service: *identity_application.Service,
    ) Service {
        return .{
            .allocator = allocator,
            .store = store,
            .identity_service = identity_service,
        };
    }

    pub fn createDraft(
        self: *Service,
        actor: Actor,
        request: domain.CreateDraft,
    ) !domain.Draft {
        return self.createDraftWithAllocator(self.allocator, actor, request);
    }

    pub fn createDraftWithAllocator(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: Actor,
        request: domain.CreateDraft,
    ) !domain.Draft {
        try authorizeCreateDraft(self, actor, request.document_id);
        try domain.validateCreateDraft(request);

        const section_data = try buildTextSection(allocator, request.markdown);
        defer allocator.free(section_data);
        return self.store.createDraft(request, section_data, userId(actor));
    }

    pub fn createNextVersion(
        self: *Service,
        actor: Actor,
        request: domain.CreateNextVersion,
    ) !domain.NextVersion {
        try authorizeCreateNextVersion(self, actor, request.source_version_id);
        try domain.validateCreateNextVersion(request);
        return version_storage.createNextVersion(self.store, self.allocator, request, userId(actor));
    }

    pub fn saveDraft(
        self: *Service,
        actor: Actor,
        request: domain.SaveDraft,
    ) !domain.SaveResult {
        return self.saveDraftWithAllocator(self.allocator, actor, request);
    }

    pub fn saveDraftWithAllocator(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: Actor,
        request: domain.SaveDraft,
    ) !domain.SaveResult {
        try authorizeDraftMutation(self, actor, request.version_id);
        try domain.validateSaveDraft(request);

        const encoded = try allocator.alloc(storage.EncodedSection, request.sections.len);
        defer allocator.free(encoded);
        var encoded_count: usize = 0;
        defer for (encoded[0..encoded_count]) |section| allocator.free(section.data);

        for (request.sections, 0..) |section, index| {
            encoded[index] = .{
                .id = section.id,
                .kind = section.payload.kind().name(),
                .data = try encodeSection(allocator, section.payload),
            };
            encoded_count += 1;
        }
        return self.store.saveDraft(request, encoded, userId(actor));
    }

    pub fn loadDraft(self: *Service, actor: Actor, version_id: i64) !LoadedDraft {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const document = try self.loadDraftDocument(actor, version_id, arena.allocator());
        return .{ .arena = arena, .document = document };
    }

    pub fn loadDraftWithAllocator(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: Actor,
        version_id: i64,
    ) !LoadedDraft {
        return .{
            .arena = null,
            .document = try self.loadDraftDocument(actor, version_id, allocator),
        };
    }

    fn loadDraftDocument(
        self: *Service,
        actor: Actor,
        version_id: i64,
        allocator: std.mem.Allocator,
    ) !domain.DraftDocument {
        try authorizeDraftRead(self, actor, version_id);

        const record = try self.store.loadDraft(allocator, version_id);
        const document_type = domain.DocumentType.parse(record.document_type) catch return error.InvalidStoredDocument;
        const version_number = std.math.cast(u32, record.version_number) orelse return error.InvalidStoredDocument;
        const revision_number = std.math.cast(u64, record.revision_number) orelse return error.InvalidStoredDocument;
        const sections = try allocator.alloc(domain.DraftSection, record.sections.len);

        for (record.sections, 0..) |section, index| {
            const position = std.math.cast(usize, section.position) orelse return error.InvalidStoredDocument;
            if (position != index) return error.InvalidStoredDocument;
            sections[index] = .{
                .id = section.id,
                .payload = try decodeSection(allocator, section.kind, section.data),
            };
        }

        return .{
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
        };
    }

    pub fn listDrafts(self: *Service, actor: Actor, allocator: std.mem.Allocator) ![]DraftSummary {
        switch (actor) {
            .local_operator => return self.store.listDrafts(allocator),
            .user => |user_id| {
                const service = self.identity_service orelse return error.AuthorizationUnavailable;
                if (try document_access.userHasCapability(service, user_id, .document_read_any)) {
                    return self.store.listDrafts(allocator);
                }
                try document_access.requireUserCapability(service, user_id, .document_read_assigned);
                return self.store.listDraftsForUser(allocator, user_id);
            },
        }
    }

    pub fn mutableVersionForDocument(self: *Service, actor: Actor, document_id: i64) !i64 {
        if (document_id <= 0) return error.InvalidDocumentId;
        try authorizeDocumentRead(self, actor, document_id);
        return self.store.mutableVersionForDocument(document_id);
    }

    pub fn insertSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Insert,
    ) !section_storage.MutationResult {
        return self.insertSectionWithAllocator(self.allocator, actor, request);
    }

    pub fn insertSectionWithAllocator(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: Actor,
        request: section_domain.Insert,
    ) !section_storage.MutationResult {
        try authorizeVersionMutation(self, actor, request.version_id);
        try section_domain.validateInsert(request);
        const data = try encodeSection(allocator, request.payload);
        defer allocator.free(data);
        return section_storage.insertSection(
            self.store,
            request.version_id,
            request.position,
            request.expected_revision,
            request.payload.kind().name(),
            data,
            userId(actor),
        );
    }

    pub fn updateSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Update,
    ) !section_storage.MutationResult {
        return self.updateSectionWithAllocator(self.allocator, actor, request);
    }

    pub fn updateSectionWithAllocator(
        self: *Service,
        allocator: std.mem.Allocator,
        actor: Actor,
        request: section_domain.Update,
    ) !section_storage.MutationResult {
        try authorizeVersionMutation(self, actor, request.version_id);
        try section_domain.validateUpdate(request);
        const data = try encodeSection(allocator, request.payload);
        defer allocator.free(data);
        return section_storage.updateSection(
            self.store,
            request.version_id,
            request.section_id,
            request.expected_revision,
            request.payload.kind().name(),
            data,
            userId(actor),
        );
    }

    pub fn moveSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Move,
    ) !section_storage.MutationResult {
        try authorizeVersionMutation(self, actor, request.version_id);
        try section_domain.validateMove(request);
        return section_storage.moveSection(
            self.store,
            request.version_id,
            request.section_id,
            request.position,
            request.expected_revision,
            userId(actor),
        );
    }

    pub fn duplicateSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Duplicate,
    ) !section_storage.MutationResult {
        try authorizeVersionMutation(self, actor, request.version_id);
        try section_domain.validateDuplicate(request);
        return section_storage.duplicateSection(
            self.store,
            request.version_id,
            request.section_id,
            request.position,
            request.expected_revision,
            userId(actor),
        );
    }

    pub fn deleteSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Delete,
    ) !section_storage.MutationResult {
        try authorizeVersionMutation(self, actor, request.version_id);
        try section_domain.validateDelete(request);
        return section_storage.deleteSection(
            self.store,
            request.version_id,
            request.section_id,
            request.expected_revision,
            userId(actor),
        );
    }
};

fn userId(actor: Actor) ?i64 {
    return switch (actor) {
        .local_operator => null,
        .user => |user_id| user_id,
    };
}

fn requireIdentity(self: *Service) !*identity_application.Service {
    return self.identity_service orelse error.AuthorizationUnavailable;
}

fn authorizeCreateDraft(self: *Service, actor: Actor, document_id: ?i64) !void {
    switch (actor) {
        .local_operator => {},
        .user => |user_id| {
            const service = try requireIdentity(self);
            try document_access.requireUserCapability(service, user_id, .document_create);
            if (document_id) |id| {
                try document_access.requireUserDocumentUpdate(service, user_id, id);
            }
        },
    }
}

fn authorizeCreateNextVersion(self: *Service, actor: Actor, version_id: i64) !void {
    switch (actor) {
        .local_operator => {},
        .user => |user_id| try document_access.requireUserVersionRead(try requireIdentity(self), user_id, version_id),
    }
}

fn authorizeDocumentRead(self: *Service, actor: Actor, document_id: i64) !void {
    switch (actor) {
        .local_operator => {},
        .user => |user_id| try document_access.requireUserDocumentRead(try requireIdentity(self), user_id, document_id),
    }
}

fn authorizeDraftRead(self: *Service, actor: Actor, version_id: i64) !void {
    switch (actor) {
        .local_operator => {},
        .user => |user_id| try document_access.requireUserVersionRead(try requireIdentity(self), user_id, version_id),
    }
}

fn authorizeDraftMutation(self: *Service, actor: Actor, version_id: i64) !void {
    switch (actor) {
        .local_operator => {},
        .user => |user_id| {
            const service = try requireIdentity(self);
            try document_access.requireUserVersionUpdate(service, user_id, version_id);
        },
    }
}

fn authorizeVersionMutation(self: *Service, actor: Actor, version_id: i64) !void {
    switch (actor) {
        .local_operator => {},
        .user => |user_id| try document_access.requireUserVersionUpdate(try requireIdentity(self), user_id, version_id),
    }
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
