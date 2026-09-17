const std = @import("std");
const tmpl = @import("tmpl");

const Status = enum { draft, published };

const Author = struct {
    name: []const u8,
};

const Post = struct {
    title: []const u8,
    author: *const Author,
    body_html: []const u8,
    count: i32,
    rating: f64,
    published: bool,
    status: Status,
};

test "renders inline text, nested paths, scalars, and escaped strings" {
    const template = tmpl.parse("<h1>{{ post.title }}</h1>\n" ++
        "<p>{{ post.author.name }} #{{ post.count }} {{ post.rating }} {{ post.published }} {{ post.status }}</p>\n" ++
        "<div>{{ post.body_html }}</div><div>{{{ post.body_html }}}</div>\n");
    const author = Author{ .name = "Ada & <Grace> '" };
    const post = Post{
        .title = "Markup \"demo\"",
        .author = &author,
        .body_html = "<strong>trusted & ready</strong>",
        .count = -3,
        .rating = 4.5,
        .published = true,
        .status = .published,
    };

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try template.render(&writer, .{ .post = post });
    try std.testing.expectEqualStrings(
        "<h1>Markup &quot;demo&quot;</h1>\n<p>Ada &amp; &lt;Grace&gt; &#39; #-3 4.5 true published</p>\n<div>&lt;strong&gt;trusted &amp; ready&lt;/strong&gt;</div><div><strong>trusted & ready</strong></div>\n",
        writer.buffered(),
    );
}

test "renders an embedded template source" {
    const template = tmpl.parse(@embedFile("fixtures/basic.html"));
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try template.render(&writer, .{ .title = "Embedded & safe" });
    try std.testing.expectEqualStrings("<h1>Embedded &amp; safe</h1>\n", writer.buffered());
}

test "streams writer failures" {
    const template = tmpl.parse("{{ title }}");
    var buffer: [2]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, template.render(&writer, .{ .title = "too long" }));
}
