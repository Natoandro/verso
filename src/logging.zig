const std = @import("std");

pub const RequestRecord = struct {
    timestamp_ms: i64,
    level: []const u8,
    event: []const u8,
    method: ?[]const u8,
    target: ?[]const u8,
    status: ?u16,
    duration_ms: i64,
    error_name: ?[]const u8,
};

pub const Logger = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator) Logger {
        return .{ .allocator = allocator };
    }

    pub fn request(self: *Logger, io: std.Io, record: RequestRecord) std.Io.Cancelable!void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        var output = std.Io.Writer.Allocating.init(self.allocator);
        defer output.deinit();
        writeRequestRecord(&output.writer, record) catch return;

        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &buffer);
        writer.interface.writeAll(output.written()) catch return;
        writer.flush() catch return;
    }
};

pub fn writeRequestRecord(writer: *std.Io.Writer, record: RequestRecord) !void {
    try std.json.Stringify.value(record, .{}, writer);
    try writer.writeByte('\n');
}

test "request records are JSON lines" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeRequestRecord(&writer, .{
        .timestamp_ms = 1_735_689_600_000,
        .level = "info",
        .event = "http.request",
        .method = "GET",
        .target = "/notes/hello?draft=true",
        .status = 200,
        .duration_ms = 3,
        .error_name = null,
    });

    try std.testing.expectEqualStrings(
        "{\"timestamp_ms\":1735689600000,\"level\":\"info\",\"event\":\"http.request\",\"method\":\"GET\",\"target\":\"/notes/hello?draft=true\",\"status\":200,\"duration_ms\":3,\"error_name\":null}\n",
        writer.buffered(),
    );
}
