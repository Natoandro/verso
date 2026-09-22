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
    var parts = std.mem.splitScalar(u8, password_hash, '$');
    if (!std.mem.eql(u8, parts.next() orelse "", "") or
        !std.mem.eql(u8, parts.next() orelse "", "argon2id") or
        !std.mem.eql(u8, parts.next() orelse "", "v=19"))
    {
        return error.InvalidPasswordHash;
    }
    const parameters = parts.next() orelse return error.InvalidPasswordHash;
    var parameter_count: usize = 0;
    var seen_memory = false;
    var seen_time = false;
    var seen_parallelism = false;
    var parameter_parts = std.mem.splitScalar(u8, parameters, ',');
    while (parameter_parts.next()) |parameter| {
        const separator = std.mem.indexOfScalar(u8, parameter, '=') orelse return error.InvalidPasswordHash;
        if (separator == 0 or separator + 1 == parameter.len) return error.InvalidPasswordHash;
        const name = parameter[0..separator];
        if (std.mem.eql(u8, name, "m")) {
            if (seen_memory) return error.InvalidPasswordHash;
            seen_memory = true;
        } else if (std.mem.eql(u8, name, "t")) {
            if (seen_time) return error.InvalidPasswordHash;
            seen_time = true;
        } else if (std.mem.eql(u8, name, "p")) {
            if (seen_parallelism) return error.InvalidPasswordHash;
            seen_parallelism = true;
        } else {
            return error.InvalidPasswordHash;
        }
        _ = std.fmt.parseUnsigned(u32, parameter[separator + 1 ..], 10) catch {
            return error.InvalidPasswordHash;
        };
        parameter_count += 1;
    }
    if (parameter_count != 3 or !seen_memory or !seen_time or !seen_parallelism) {
        return error.InvalidPasswordHash;
    }
    const salt = parts.next() orelse return error.InvalidPasswordHash;
    const digest = parts.next() orelse return error.InvalidPasswordHash;
    if (salt.len == 0 or digest.len == 0 or parts.next() != null) {
        return error.InvalidPasswordHash;
    }
    for (salt) |character| if (!isArgon2Base64(character)) return error.InvalidPasswordHash;
    for (digest) |character| if (!isArgon2Base64(character)) return error.InvalidPasswordHash;
}

fn isArgon2Base64(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or character == '.' or character == '/' or character == '+';
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
    argon2.strVerify(password_hash, password, .{ .allocator = allocator }, io) catch |failure| switch (failure) {
        error.InvalidEncoding,
        error.NoSpaceLeft,
        error.PasswordVerificationFailed,
        error.WeakParameters,
        => return false,
        else => return failure,
    };
    return true;
}

test "local password validation keeps login normalization and password policy separate" {
    var login_buffer: [320]u8 = undefined;
    try std.testing.expectEqualStrings("owner@example.test", try normalizeLogin(&login_buffer, "owner@example.test"));
    try std.testing.expectError(error.InvalidLogin, normalizeLogin(&login_buffer, " owner@example.test"));
    try std.testing.expectError(error.InvalidPassword, validatePassword("too-short"));
    try validatePassword("correct horse battery staple");
}

test "encoded password validation checks the Argon2id structure" {
    try validateEncodedHash("$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA");
    try std.testing.expectError(error.InvalidPasswordHash, validateEncodedHash("$argon2id$v=19$test"));
    try std.testing.expectError(error.InvalidPasswordHash, validateEncodedHash("$argon2id$v=19$x=1,t=2,p=1$c2FsdA$aGFzaA"));
}

test "password verification treats weak stored parameters as invalid credentials" {
    try std.testing.expect(!try verify(
        std.testing.allocator,
        std.testing.io,
        "$argon2id$v=19$m=0,t=0,p=0$c2FsdA$aGFzaA",
        "correct horse battery staple",
    ));
}
