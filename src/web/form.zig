const std = @import("std");
const context = @import("context.zig");

pub const max_body_bytes = 16 * 1024;

pub const Values = struct {
    body: []u8,
    login: ?[]const u8 = null,
    password: ?[]const u8 = null,
    current_password: ?[]const u8 = null,
    new_password: ?[]const u8 = null,
    token: ?[]const u8 = null,
    csrf_token: ?[]const u8 = null,

    pub fn deinit(self: *Values, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }

    pub fn required(self: Values, field: []const u8) ![]const u8 {
        return if (std.mem.eql(u8, field, "login")) self.login orelse error.MissingFormField else if (std.mem.eql(u8, field, "password")) self.password orelse error.MissingFormField else if (std.mem.eql(u8, field, "current_password")) self.current_password orelse error.MissingFormField else if (std.mem.eql(u8, field, "new_password")) self.new_password orelse error.MissingFormField else if (std.mem.eql(u8, field, "token")) self.token orelse error.MissingFormField else error.UnknownFormField;
    }
};

pub fn read(request: *context.RequestContext) !Values {
    const content_type = request.request.head.content_type orelse return error.InvalidForm;
    if (!std.ascii.eqlIgnoreCase(content_type, "application/x-www-form-urlencoded")) {
        return error.InvalidForm;
    }
    if (request.request.head.content_length) |length| {
        if (length > max_body_bytes) return error.BodyTooLarge;
    }

    var read_buffer: [4096]u8 = undefined;
    const reader = try request.request.readerExpectContinue(&read_buffer);
    const body = try reader.allocRemaining(request.server.allocator, .limited(max_body_bytes + 1));
    var values = Values{ .body = body };
    errdefer values.deinit(request.server.allocator);
    if (body.len > max_body_bytes) return error.BodyTooLarge;

    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidForm;
        const key = pair[0..separator];
        const value = try decode(@constCast(pair[separator + 1 ..]));
        if (std.mem.eql(u8, key, "login")) {
            if (values.login != null) return error.DuplicateFormField;
            values.login = value;
        } else if (std.mem.eql(u8, key, "password")) {
            if (values.password != null) return error.DuplicateFormField;
            values.password = value;
        } else if (std.mem.eql(u8, key, "current_password")) {
            if (values.current_password != null) return error.DuplicateFormField;
            values.current_password = value;
        } else if (std.mem.eql(u8, key, "new_password")) {
            if (values.new_password != null) return error.DuplicateFormField;
            values.new_password = value;
        } else if (std.mem.eql(u8, key, "token")) {
            if (values.token != null) return error.DuplicateFormField;
            values.token = value;
        } else if (std.mem.eql(u8, key, "csrf_token")) {
            if (values.csrf_token != null) return error.DuplicateFormField;
            values.csrf_token = value;
        }
    }
    return values;
}

fn decode(component: []u8) ![]u8 {
    var output: usize = 0;
    var index: usize = 0;
    while (index < component.len) : (index += 1) {
        const character = component[index];
        if (character == '+') {
            component[output] = ' ';
        } else if (character == '%') {
            if (index + 2 >= component.len) return error.InvalidForm;
            const high = std.fmt.charToDigit(component[index + 1], 16) catch return error.InvalidForm;
            const low = std.fmt.charToDigit(component[index + 2], 16) catch return error.InvalidForm;
            component[output] = high * 16 + low;
            index += 2;
        } else {
            component[output] = character;
        }
        output += 1;
    }
    return component[0..output];
}

test "form parser decodes fields and rejects malformed input" {
    const login = try std.testing.allocator.dupe(u8, "Owner%40Example.test");
    defer std.testing.allocator.free(login);
    const password = try std.testing.allocator.dupe(u8, "correct+horse");
    defer std.testing.allocator.free(password);
    try std.testing.expectEqualStrings("Owner@Example.test", try decode(login));
    try std.testing.expectEqualStrings("correct horse", try decode(password));
    const malformed = try std.testing.allocator.dupe(u8, "%0");
    defer std.testing.allocator.free(malformed);
    try std.testing.expectError(error.InvalidForm, decode(malformed));
}
