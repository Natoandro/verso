const std = @import("std");

pub const secret_bytes = 32;
pub const encoded_secret_length = secret_bytes * 2;

pub fn newSecret() [encoded_secret_length]u8 {
    var bytes: [secret_bytes]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

pub fn hashSecret(secret: []const u8) [encoded_secret_length]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(secret, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn secretMatches(secret: []const u8, expected_hash: []const u8) bool {
    const actual_hash = hashSecret(secret);
    return constantTimeEqual(&actual_hash, expected_hash);
}

pub fn constantTimeEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    var difference: u8 = 0;
    for (left, right) |left_byte, right_byte| difference |= left_byte ^ right_byte;
    return difference == 0;
}

test "secret hashing is stable and comparisons are constant-shape" {
    const first = hashSecret("session-token");
    const second = hashSecret("session-token");
    const different = hashSecret("other-token");
    try std.testing.expect(secretMatches("session-token", &first));
    try std.testing.expect(constantTimeEqual(&first, &second));
    try std.testing.expect(!constantTimeEqual(&first, &different));
    try std.testing.expect(!constantTimeEqual(&first, "short"));
}
