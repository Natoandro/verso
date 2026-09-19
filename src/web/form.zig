const std = @import("std");
const context = @import("context.zig");

pub const max_body_bytes = 16 * 1024;

pub fn Extracted(comptime Schema: type) type {
    validateSchema(Schema);
    return struct {
        value: Schema,
        body: []u8,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.body);
            self.* = undefined;
        }
    };
}

pub fn extract(comptime Schema: type, request: *context.RequestContext) !Extracted(Schema) {
    try validateContentType(request.request.head.content_type);
    try validateContentLength(request.request.head.content_length);

    var read_buffer: [4096]u8 = undefined;
    const reader = try request.request.readerExpectContinue(&read_buffer);
    const body = try reader.allocRemaining(request.server.allocator, .limited(max_body_bytes + 1));
    if (body.len > max_body_bytes) {
        request.server.allocator.free(body);
        return error.BodyTooLarge;
    }
    return parseBody(Schema, body, request.server.allocator);
}

fn validateContentType(content_type: ?[]const u8) !void {
    const value = content_type orelse return error.InvalidForm;
    if (!std.ascii.eqlIgnoreCase(value, "application/x-www-form-urlencoded")) return error.InvalidForm;
}

fn validateContentLength(content_length: ?u64) !void {
    if (content_length) |length| if (length > max_body_bytes) return error.BodyTooLarge;
}

fn parseBody(comptime Schema: type, body: []u8, allocator: std.mem.Allocator) !Extracted(Schema) {
    var parsed = Extracted(Schema){ .value = undefined, .body = body };
    errdefer parsed.deinit(allocator);
    const fields = @typeInfo(Schema).@"struct".fields;
    var present: [fields.len]bool = [_]bool{false} ** fields.len;
    initializeOptionals(Schema, &parsed.value);

    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidForm;
        const key = pair[0..separator];
        const value = try decode(@constCast(pair[separator + 1 ..]));
        try assignField(Schema, &parsed.value, &present, key, value);
    }

    inline for (fields, 0..) |field, index| {
        if (!present[index] and !isOptional(field.type)) return error.MissingFormField;
    }
    return parsed;
}

fn assignField(comptime Schema: type, values: *Schema, present: anytype, key: []const u8, value: []u8) !void {
    const fields = @typeInfo(Schema).@"struct".fields;
    inline for (fields, 0..) |field, index| {
        if (std.mem.eql(u8, key, field.name)) {
            if (present.*[index]) return error.DuplicateFormField;
            @field(values.*, field.name) = try parseFieldValue(field.type, value);
            present.*[index] = true;
            return;
        }
    }
}

fn initializeOptionals(comptime Schema: type, values: *Schema) void {
    inline for (@typeInfo(Schema).@"struct".fields) |field| {
        if (comptime isOptional(field.type)) @field(values.*, field.name) = null;
    }
}

fn parseFieldValue(comptime T: type, value: []const u8) !T {
    if (T == []const u8) return value;
    switch (@typeInfo(T)) {
        .optional => |info| return @as(T, try parseFieldValue(info.child, value)),
        .int => |info| {
            if (info.signedness == .signed) return std.fmt.parseInt(T, value, 10) catch error.InvalidForm;
            return std.fmt.parseUnsigned(T, value, 10) catch error.InvalidForm;
        },
        else => unreachable,
    }
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn validateSchema(comptime Schema: type) void {
    if (@typeInfo(Schema) != .@"struct") @compileError("form schema must be a struct");
    inline for (@typeInfo(Schema).@"struct".fields) |field| {
        if (!isSupportedFieldType(field.type)) {
            @compileError(std.fmt.comptimePrint("unsupported form field type for '{s}'", .{field.name}));
        }
    }
}

fn isSupportedFieldType(comptime T: type) bool {
    if (T == []const u8) return true;
    return switch (@typeInfo(T)) {
        .int => true,
        .optional => |info| info.child == []const u8 or @typeInfo(info.child) == .int,
        else => false,
    };
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

test "typed form extraction distinguishes required and optional values" {
    const Schema = struct {
        title: []const u8,
        description: ?[]const u8,
        revision: u64,
    };
    var parsed = try parseBody(
        Schema,
        try std.testing.allocator.dupe(u8, "title=Draft&description=&revision=0&extra=ignored"),
        std.testing.allocator,
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Draft", parsed.value.title);
    try std.testing.expectEqualStrings("", parsed.value.description.?);
    try std.testing.expectEqual(@as(u64, 0), parsed.value.revision);

    var without_optional = try parseBody(
        Schema,
        try std.testing.allocator.dupe(u8, "title=Draft&revision=0"),
        std.testing.allocator,
    );
    defer without_optional.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?[]const u8, null), without_optional.value.description);
}

test "typed form extraction rejects missing, duplicate, and invalid fields" {
    const Schema = struct {
        title: []const u8,
        revision: u64,
    };
    try std.testing.expectError(
        error.MissingFormField,
        parseBody(Schema, try std.testing.allocator.dupe(u8, "title=Draft"), std.testing.allocator),
    );
    try std.testing.expectError(
        error.DuplicateFormField,
        parseBody(Schema, try std.testing.allocator.dupe(u8, "title=One&title=Two&revision=1"), std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidForm,
        parseBody(Schema, try std.testing.allocator.dupe(u8, "title=Draft&revision=nope"), std.testing.allocator),
    );
}

test "typed form extraction parses signed and optional integers" {
    const Schema = struct {
        offset: i64,
        revision: ?u64,
    };
    var parsed = try parseBody(
        Schema,
        try std.testing.allocator.dupe(u8, "offset=-3&revision=0"),
        std.testing.allocator,
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, -3), parsed.value.offset);
    try std.testing.expectEqual(@as(?u64, 0), parsed.value.revision);
}

test "form transport constraints enforce content type and body limit" {
    try std.testing.expectError(error.InvalidForm, validateContentType(null));
    try std.testing.expectError(error.InvalidForm, validateContentType("text/plain"));
    try validateContentType("Application/X-WWW-Form-Urlencoded");
    try validateContentLength(max_body_bytes);
    try std.testing.expectError(error.BodyTooLarge, validateContentLength(max_body_bytes + 1));
}
