const std = @import("std");

pub const minimum_length = 12;
pub const maximum_length = 1024;
pub const encoded_hash_capacity = 512;

const argon2 = std.crypto.pwhash.argon2;

pub fn validateLogin(login: []const u8) !void {
    const trimmed = std.mem.trim(u8, login, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed.len > 320 or !std.mem.eql(u8, trimmed, login)) {
        return error.InvalidLogin;
    }
    for (trimmed) |character| {
        if (character < 0x20 or character == 0x7f) return error.InvalidLogin;
    }
}

pub fn normalizeLogin(buffer: []u8, login: []const u8) ![]const u8 {
    try validateLogin(login);
    if (login.len > buffer.len) return error.InvalidLogin;
    for (login, 0..) |character, index| {
        buffer[index] = std.ascii.toLower(character);
    }
    return buffer[0..login.len];
}

pub fn validatePassword(password: []const u8) !void {
    if (password.len < minimum_length or password.len > maximum_length) {
        return error.InvalidPassword;
    }
    for (password) |character| {
        if (character == 0) return error.InvalidPassword;
    }
}

pub fn validateEncodedHash(password_hash: []const u8) !void {
    if (password_hash.len == 0 or password_hash.len > encoded_hash_capacity or
        !std.mem.startsWith(u8, password_hash, "$argon2id$v=19$"))
    {
        return error.InvalidPasswordHash;
    }
}

pub fn hash(
    allocator: std.mem.Allocator,
    io: std.Io,
    password: []const u8,
    output: *[encoded_hash_capacity]u8,
) ![]const u8 {
    try validatePassword(password);
    return argon2.strHash(password, .{
        .allocator = allocator,
        .params = argon2.Params.owasp_2id,
        .mode = .argon2id,
    }, output, io);
}

pub fn verify(
    allocator: std.mem.Allocator,
    io: std.Io,
    password_hash: []const u8,
    password: []const u8,
) !bool {
    if (password.len > maximum_length) return false;
    argon2.strVerify(password_hash, password, .{ .allocator = allocator }, io) catch return false;
    return true;
}

test "local password validation keeps login normalization and password policy separate" {
    var login_buffer: [320]u8 = undefined;
    try std.testing.expectEqualStrings("owner@example.test", try normalizeLogin(&login_buffer, "owner@example.test"));
    try std.testing.expectError(error.InvalidLogin, normalizeLogin(&login_buffer, " owner@example.test"));
    try std.testing.expectError(error.InvalidPassword, validatePassword("too-short"));
    try validatePassword("correct horse battery staple");
}
