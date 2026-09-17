const tmpl = @import("tmpl");

const Post = struct {
    title: []const u8,
};

comptime {
    const template = tmpl.parse("{{ post.titel }}");
    var buffer: [32]u8 = undefined;
    var writer = @import("std").Io.Writer.fixed(&buffer);
    template.render(&writer, .{ .post = Post{ .title = "title" } }) catch unreachable;
}
