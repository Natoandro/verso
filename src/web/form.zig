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
    display_name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    slug: ?[]const u8 = null,
    biography: ?[]const u8 = null,
    editor_user_id: ?[]const u8 = null,
    scope_type: ?[]const u8 = null,
    scope_id: ?[]const u8 = null,
    expected_revision: ?[]const u8 = null,
    document_id: ?[]const u8 = null,
    version_id: ?[]const u8 = null,
    section_id: ?[]const u8 = null,
    position: ?[]const u8 = null,
    operation: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    language: ?[]const u8 = null,
    markdown: ?[]const u8 = null,
    asset: ?[]const u8 = null,
    alt: ?[]const u8 = null,
    caption: ?[]const u8 = null,
    display: ?[]const u8 = null,

    pub fn deinit(self: *Values, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }

    pub fn required(self: Values, comptime field: []const u8) ![]const u8 {
        if (!@hasField(Values, field)) @compileError("unknown form field");
        const value = @field(self, field);
        if (@TypeOf(value) != ?[]const u8) @compileError("form field is not optional text");
        return value orelse error.MissingFormField;
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
        try assignField(&values, key, value);
    }
    return values;
}

fn assignField(values: *Values, key: []const u8, value: []u8) !void {
    inline for (@typeInfo(Values).@"struct".fields) |field| {
        if (comptime @TypeOf(@field(values.*, field.name)) == ?[]const u8) {
            if (std.mem.eql(u8, key, field.name)) {
                const destination = &@field(values.*, field.name);
                if (destination.* != null) return error.DuplicateFormField;
                destination.* = value;
                return;
            }
        }
    }
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
