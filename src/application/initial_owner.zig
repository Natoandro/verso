const std = @import("std");
const auth_crypto = @import("../auth/crypto.zig");
const identity = @import("../auth/identity.zig");
const password = @import("../auth/password.zig");
const storage = @import("../storage/identity.zig");

pub const Profile = struct {
    subject: ?[]const u8 = null,
    display_name: []const u8,
    email: ?[]const u8 = null,
};

pub const LocalCredentials = struct {
    login: []const u8,
    password_hash: []const u8,
};

pub const Service = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *storage.Store,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, store: *storage.Store) Service {
        return .{ .io = io, .allocator = allocator, .store = store };
    }

    pub fn provisionLocal(self: *Service, profile: Profile, credentials: LocalCredentials) !i64 {
        try validateProfile(profile);
        try password.validateLogin(credentials.login);
        try password.validateEncodedHash(credentials.password_hash);

        var login_buffer: [320]u8 = undefined;
        const normalized_login = try password.normalizeLogin(&login_buffer, credentials.login);
        var generated_secret: [auth_crypto.encoded_secret_length]u8 = undefined;
        var generated_subject: [6 + auth_crypto.encoded_secret_length]u8 = undefined;
        const subject = profile.subject orelse blk: {
            generated_secret = try auth_crypto.newSecret(self.io);
            break :blk try std.fmt.bufPrint(&generated_subject, "local:{s}", .{&generated_secret});
        };

        return self.store.createInitialLocalOwner(.{
            .subject = subject,
            .display_name = profile.display_name,
            .email = profile.email,
            .login = normalized_login,
            .password_hash = credentials.password_hash,
        });
    }

    pub fn hashAndProvisionLocal(
        self: *Service,
        profile: Profile,
        login: []const u8,
        password_text: []const u8,
    ) !i64 {
        try password.validatePassword(password_text);
        var password_hash: [password.encoded_hash_capacity]u8 = undefined;
        const encoded_hash = try password.hash(self.allocator, self.io, password_text, &password_hash);
        return self.provisionLocal(profile, .{
            .login = login,
            .password_hash = encoded_hash,
        });
    }

    fn validateProfile(profile: Profile) !void {
        if (profile.subject) |subject| {
            try identity.validateBootstrapOwner(.{
                .subject = subject,
                .display_name = profile.display_name,
                .email = profile.email,
            });
        } else {
            try identity.validateDisplayName(profile.display_name);
            if (profile.email) |email| try identity.validateEmail(email);
        }
    }
};

test "local initial owner provisioning generates a subject and only succeeds once" {
    const sqlite = @import("sqlite");
    const logging = @import("../logging.zig");
    const migrations = @import("../storage/migrations.zig");

    var database = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer database.deinit();
    var logger = logging.Logger.init(std.testing.allocator, .text);
    var migration_context = migrations.MigrationContext.init(
        std.testing.io,
        std.testing.allocator,
        "migrations",
        &database,
        &logger,
    );
    _ = try migration_context.migrateUp();

    var store = storage.Store.init(&database);
    var service = Service.init(std.testing.io, std.testing.allocator, &store);
    const owner_id = try service.hashAndProvisionLocal(
        .{ .display_name = "Site Owner", .email = "owner@example.test" },
        "Owner@Example.test",
        "correct horse battery staple",
    );
    try std.testing.expectEqual(@as(i64, 1), owner_id);

    const SubjectRow = struct { subject: sqlite.Text };
    const subject = (try database.oneAlloc(
        SubjectRow,
        std.testing.allocator,
        "SELECT subject FROM users WHERE id = ?",
        .{},
        .{owner_id},
    )).?;
    defer std.testing.allocator.free(subject.subject.data);
    try std.testing.expect(std.mem.startsWith(u8, subject.subject.data, "local:"));
    try std.testing.expectError(
        error.OwnerAlreadyExists,
        service.hashAndProvisionLocal(
            .{ .display_name = "Second Owner" },
            "second@example.test",
            "correct horse battery staple",
        ),
    );
}
