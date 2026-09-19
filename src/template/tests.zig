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

const User = struct {
    name: []const u8,
};

const Item = struct {
    name: []const u8,
};

const Group = struct {
    name: []const u8,
    items: []const Item,
};

const large_template_chunk = "<span>{{ title }}</span>";
const large_rendered_chunk = "<span>bounded</span>";
const large_template_source = makeLargeTemplateSource();

fn makeLargeTemplateSource() [large_template_chunk.len * 256]u8 {
    var source: [large_template_chunk.len * 256]u8 = undefined;
    inline for (0..256) |index| {
        @memcpy(source[index * large_template_chunk.len ..][0..large_template_chunk.len], large_template_chunk);
    }
    return source;
}

const ComponentPost = struct {
    id: i32,
    title: []const u8,
};

test "renders inline text, nested paths, scalars, and escaped strings" {
    const template = tmpl.parse("<h1>{{ post.title }}</h1>\n" ++
        "<p>{{ post.author.name }} #{{ post.count }} {{ post.rating }} {{ post.published }} {{ post.status }}</p>\n" ++
        "<div>{{ post.body_html }}</div><div>{{{ post.body_html }}}</div>\n", .{});
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
    const template = tmpl.parse(@embedFile("fixtures/basic.html"), .{});
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try template.render(&writer, .{ .title = "Embedded & safe" });
    try std.testing.expectEqualStrings("<h1>Embedded &amp; safe</h1>\n", writer.buffered());
}

test "renderAlloc collects the writer renderer output" {
    const template = tmpl.parse("<h1>{{ title }}</h1>", .{});
    const rendered = try template.renderAlloc(std.testing.allocator, .{ .title = "Collected & safe" });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("<h1>Collected &amp; safe</h1>", rendered);
}

test "streams writer failures" {
    const template = tmpl.parse("{{ title }}", .{});
    var buffer: [2]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, template.render(&writer, .{ .title = "too long" }));
}

test "renders large flat templates through bounded operation dispatch" {
    const template = tmpl.parse(large_template_source[0..], .{});
    var output_buffer: [large_rendered_chunk.len * 256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try template.render(&output, .{ .title = "bounded" });

    var expected_buffer: [large_rendered_chunk.len * 256]u8 = undefined;
    var expected = std.Io.Writer.fixed(&expected_buffer);
    inline for (0..256) |_| try expected.writeAll(large_rendered_chunk);
    try std.testing.expectEqualStrings(expected.buffered(), output.buffered());
}

test "renders boolean branches and comments" {
    const template = tmpl.parse("before{{! ignored }}{{#if enabled}}yes{{#else}}no{{/if}}after", .{});
    var buffer: [64]u8 = undefined;

    var writer = std.Io.Writer.fixed(&buffer);
    try template.render(&writer, .{ .enabled = true });
    try std.testing.expectEqualStrings("beforeyesafter", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try template.render(&writer, .{ .enabled = false });
    try std.testing.expectEqualStrings("beforenoafter", writer.buffered());
}

test "renders optional captures and else branches" {
    const template = tmpl.parse("{{#if current_user |user|}}Hello {{ user.name }}{{#else}}Guest{{/if}}", .{});
    const present = User{ .name = "Ada" };
    var buffer: [64]u8 = undefined;

    var writer = std.Io.Writer.fixed(&buffer);
    try template.render(&writer, .{ .current_user = @as(?User, present) });
    try std.testing.expectEqualStrings("Hello Ada", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try template.render(&writer, .{ .current_user = @as(?User, null) });
    try std.testing.expectEqualStrings("Guest", writer.buffered());
}

test "renders nested array and slice loops" {
    const first_items = [_]Item{ .{ .name = "a" }, .{ .name = "b" } };
    const second_items = [_]Item{.{ .name = "c" }};
    const groups = [_]Group{
        .{ .name = "one", .items = &first_items },
        .{ .name = "two", .items = &second_items },
    };
    const template = tmpl.parse("{{#for groups |group|}}[{{ group.name }}:{{#for group.items |item|}}{{ item.name }}{{/for}}]{{/for}}", .{});
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try template.render(&writer, .{ .groups = groups });
    try std.testing.expectEqualStrings("[one:ab][two:c]", writer.buffered());
}

test "renders a registered component with named path and literal arguments" {
    const card = tmpl.parse(
        "<article data-id=\"{{ id }}\"><h2>{{ title }}</h2><p>{{ active }}</p><span>{{ count }}</span><small>{{ label }}</small></article>",
        .{ .parameters = .{ .id = {}, .title = {}, .active = {}, .count = {}, .label = {} } },
    );
    const page = tmpl.parse(
        "{{> card id=post.id title=post.title active=true count=3 label=\"featured post\"}}",
        .{ .components = .{ .card = card } },
    );
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try page.render(&writer, .{ .post = ComponentPost{ .id = 7, .title = "Components" } });
    try std.testing.expectEqualStrings(
        "<article data-id=\"7\"><h2>Components</h2><p>true</p><span>3</span><small>featured post</small></article>",
        writer.buffered(),
    );
}

test "renders nested registered components" {
    const badge = tmpl.parse("<em>{{ text }}</em>", .{ .parameters = .{ .text = {} } });
    const card = tmpl.parse(
        "<strong>{{ name }}</strong>{{> badge text=name}}",
        .{ .parameters = .{ .name = {} }, .components = .{ .badge = badge } },
    );
    const page = tmpl.parse("{{> card name=title}}", .{ .components = .{ .card = card } });
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try page.render(&writer, .{ .title = "Nested" });
    try std.testing.expectEqualStrings("<strong>Nested</strong><em>Nested</em>", writer.buffered());
}

test "composes layout slots and keeps content independently renderable" {
    const chrome = tmpl.parse(
        "<div class=\"chrome\">{{ text }}</div>",
        .{ .parameters = .{ .text = {} } },
    );
    const content = tmpl.parse("<main>{{ title }}</main>", .{ .parameters = .{ .title = {} } });
    const layout = tmpl.layout(
        "{{> header text=title}}{{> content title=title}}{{> footer text=title}}",
    );
    const page = layout.with(.{ .header = chrome, .content = content, .footer = chrome });

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try page.render(&writer, .{ .title = "Composed" });
    try std.testing.expectEqualStrings(
        "<div class=\"chrome\">Composed</div><main>Composed</main><div class=\"chrome\">Composed</div>",
        writer.buffered(),
    );

    writer = std.Io.Writer.fixed(&buffer);
    try content.render(&writer, .{ .title = "Fragment" });
    try std.testing.expectEqualStrings("<main>Fragment</main>", writer.buffered());
}

test "renders local snippets with positional and named arguments" {
    const template = tmpl.parse(
        "{{> link title \"read more\"}}{{#snippet link |href, label|}}<a href=\"{{ href }}\">{{ label }}</a>{{/snippet}}",
        .{},
    );
    const named_template = tmpl.parse(
        "{{> link label=\"read more\" href=title}}{{#snippet link |href, label|}}<a href=\"{{ href }}\">{{ label }}</a>{{/snippet}}",
        .{},
    );
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try template.render(&writer, .{ .title = "/posts/1" });
    try std.testing.expectEqualStrings("<a href=\"/posts/1\">read more</a>", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try named_template.render(&writer, .{ .title = "/posts/1" });
    try std.testing.expectEqualStrings("<a href=\"/posts/1\">read more</a>", writer.buffered());
}

test "renders multiple snippets after their declarations" {
    const template = tmpl.parse(
        "{{#snippet bold |value|}}<b>{{ value }}</b>{{/snippet}}{{#snippet italic |value|}}<i>{{ value }}</i>{{/snippet}}{{> bold title}}{{> italic title}}",
        .{},
    );
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try template.render(&writer, .{ .title = "Text" });
    try std.testing.expectEqualStrings("<b>Text</b><i>Text</i>", writer.buffered());
}

test "resolves nested snippets lexically and shadows external components" {
    const external_badge = tmpl.parse("<i>{{ text }}</i>", .{ .parameters = .{ .text = {} } });
    const template = tmpl.parse(
        "{{> article post}}{{#snippet article |article|}}{{#snippet heading |text|}}<h2>{{ text }}</h2>{{/snippet}}{{#snippet article |article|}}<strong>{{ article.title }}</strong>{{/snippet}}<article>{{> heading article.title}}{{> article article}}{{> badge text=article.title}}</article>{{/snippet}}",
        .{ .components = .{ .article = external_badge, .heading = external_badge, .badge = external_badge } },
    );
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try template.render(&writer, .{ .post = ComponentPost{ .id = 1, .title = "Lexical" } });
    try std.testing.expectEqualStrings("<article><h2>Lexical</h2><strong>Lexical</strong><i>Lexical</i></article>", writer.buffered());
}

test "resolves snippets declared in loop bodies" {
    const posts = [_]ComponentPost{
        .{ .id = 1, .title = "First" },
        .{ .id = 2, .title = "Second" },
    };
    const template = tmpl.parse(
        "{{#for posts |post|}}{{> card post}}{{#snippet card |post|}}<p>{{ post.title }}</p>{{/snippet}}{{/for}}",
        .{},
    );
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try template.render(&writer, .{ .posts = posts });
    try std.testing.expectEqualStrings("<p>First</p><p>Second</p>", writer.buffered());
}
