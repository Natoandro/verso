const std = @import("std");
const escape = @import("tmpl").escape;

pub fn renderAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var lines = std.mem.splitScalar(u8, source, '\n');
    var paragraph = std.Io.Writer.Allocating.init(allocator);
    defer paragraph.deinit();

    while (lines.next()) |raw_line| {
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "```")) {
            try output.writer.writeAll("<pre><code>");
            while (lines.next()) |raw_code| {
                const code = if (std.mem.endsWith(u8, raw_code, "\r")) raw_code[0 .. raw_code.len - 1] else raw_code;
                if (std.mem.eql(u8, code, "```") or std.mem.startsWith(u8, code, "```")) break;
                try escape.write(&output.writer, code, true);
                try output.writer.writeByte('\n');
            }
            try output.writer.writeAll("</code></pre>");
            continue;
        }
        if (headingLevel(line)) |heading| {
            try output.writer.print("<h{d}>", .{heading.level});
            try renderInline(&output.writer, heading.content);
            try output.writer.print("</h{d}>", .{heading.level});
            continue;
        }
        if (std.mem.startsWith(u8, line, ">")) {
            try output.writer.writeAll("<blockquote><p>");
            var quote = line[1..];
            if (quote.len > 0 and quote[0] == ' ') quote = quote[1..];
            try renderInline(&output.writer, quote);
            try output.writer.writeAll("</p></blockquote>");
            continue;
        }
        if (listItem(line)) |item| {
            const ordered = item.ordered;
            try output.writer.writeAll(if (ordered) "<ol>" else "<ul>");
            var current = line;
            while (listItem(current)) |entry| {
                if (entry.ordered != ordered) break;
                try output.writer.writeAll("<li>");
                try renderInline(&output.writer, entry.content);
                try output.writer.writeAll("</li>");
                const next_raw = lines.peek() orelse break;
                current = if (std.mem.endsWith(u8, next_raw, "\r")) next_raw[0 .. next_raw.len - 1] else next_raw;
                if (listItem(current) == null) break;
                _ = lines.next();
            }
            try output.writer.writeAll(if (ordered) "</ol>" else "</ul>");
            continue;
        }

        paragraph.clearRetainingCapacity();
        try renderInline(&paragraph.writer, line);
        try output.writer.writeAll("<p>");
        try output.writer.writeAll(paragraph.written());
        while (lines.peek()) |next_raw| {
            const next = if (std.mem.endsWith(u8, next_raw, "\r")) next_raw[0 .. next_raw.len - 1] else next_raw;
            if (next.len == 0 or headingLevel(next) != null or listItem(next) != null or
                std.mem.startsWith(u8, next, ">") or std.mem.startsWith(u8, next, "```")) break;
            _ = lines.next();
            try output.writer.writeAll("<br>");
            try renderInline(&output.writer, next);
        }
        try output.writer.writeAll("</p>");
    }
    return output.toOwnedSlice();
}

pub fn imagePlaceholder(
    allocator: std.mem.Allocator,
    alt: []const u8,
    caption: ?[]const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("<figure class=\"preview-image-placeholder\"><div>Image placeholder</div>");
    if (alt.len > 0) {
        try output.writer.writeAll("<p>Alt text: ");
        try escape.write(&output.writer, alt, true);
        try output.writer.writeAll("</p>");
    }
    if (caption) |value| if (value.len > 0) {
        try output.writer.writeAll("<figcaption>");
        try escape.write(&output.writer, value, true);
        try output.writer.writeAll("</figcaption>");
    };
    try output.writer.writeAll("</figure>");
    return output.toOwnedSlice();
}

const Heading = struct { level: u8, content: []const u8 };

fn headingLevel(line: []const u8) ?Heading {
    var level: usize = 0;
    while (level < line.len and level < 6 and line[level] == '#') : (level += 1) {}
    if (level == 0 or level == line.len or line[level] != ' ') return null;
    return .{ .level = @intCast(level), .content = std.mem.trim(u8, line[level + 1 ..], " ") };
}

const ListItem = struct { ordered: bool, content: []const u8 };

fn listItem(line: []const u8) ?ListItem {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') {
        return .{ .ordered = false, .content = line[2..] };
    }
    var index: usize = 0;
    while (index < line.len and std.ascii.isDigit(line[index])) : (index += 1) {}
    if (index > 0 and index + 1 < line.len and line[index] == '.' and line[index + 1] == ' ') {
        return .{ .ordered = true, .content = line[index + 2 ..] };
    }
    return null;
}

fn renderInline(writer: *std.Io.Writer, source: []const u8) !void {
    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == '`') {
            if (std.mem.indexOfScalarPos(u8, source, index + 1, '`')) |end| {
                try writer.writeAll("<code>");
                try escape.write(writer, source[index + 1 .. end], true);
                try writer.writeAll("</code>");
                index = end + 1;
                continue;
            }
        }
        if (std.mem.startsWith(u8, source[index..], "**")) {
            if (std.mem.indexOfPos(u8, source, index + 2, "**")) |end| {
                try writer.writeAll("<strong>");
                try renderInline(writer, source[index + 2 .. end]);
                try writer.writeAll("</strong>");
                index = end + 2;
                continue;
            }
        }
        if (source[index] == '*' or source[index] == '_') {
            const marker = source[index];
            if (std.mem.indexOfScalarPos(u8, source, index + 1, marker)) |end| {
                try writer.writeAll("<em>");
                try renderInline(writer, source[index + 1 .. end]);
                try writer.writeAll("</em>");
                index = end + 1;
                continue;
            }
        }
        if (source[index] == '[' or (source[index] == '!' and index + 1 < source.len and source[index + 1] == '[')) {
            const image = source[index] == '!';
            const label_start = index + @as(usize, if (image) 2 else 1);
            if (std.mem.indexOfScalarPos(u8, source, label_start, ']')) |label_end| {
                if (label_end + 1 < source.len and source[label_end + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, source, label_end + 2, ')')) |url_end| {
                        const url = source[label_end + 2 .. url_end];
                        if (safeUrl(url)) {
                            if (image) {
                                try writer.writeAll("<img src=\"");
                                try escape.write(writer, url, true);
                                try writer.writeAll("\" alt=\"");
                                try escape.write(writer, source[label_start..label_end], true);
                                try writer.writeAll("\" loading=\"lazy\">");
                            } else {
                                try writer.writeAll("<a href=\"");
                                try escape.write(writer, url, true);
                                try writer.writeAll("\">");
                                try renderInline(writer, source[label_start..label_end]);
                                try writer.writeAll("</a>");
                            }
                            index = url_end + 1;
                            continue;
                        }
                    }
                }
            }
        }
        const start = index;
        index += 1;
        while (index < source.len and source[index] != '`' and source[index] != '*' and
            source[index] != '_' and source[index] != '[' and source[index] != '!') : (index += 1)
        {}
        try escape.write(writer, source[start..index], true);
    }
}

fn safeUrl(url: []const u8) bool {
    if (url.len == 0 or std.mem.startsWith(u8, url, "//")) return false;
    for (url) |character| if (character <= 0x20 or character == 0x7f or character == '<' or character == '>' or character == '"' or character == '\'') return false;
    if (std.mem.indexOfScalar(u8, url, ':')) |colon| {
        const scheme = url[0..colon];
        return std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "mailto");
    }
    return true;
}

test "markdown renderer escapes raw markup and renders blocks" {
    const html = try renderAlloc(std.testing.allocator, "# Hello\n\n**world**");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<h1>Hello</h1><p><strong>world</strong></p>", html);
    const escaped = try renderAlloc(std.testing.allocator, "<script>");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("<p>&lt;script&gt;</p>", escaped);
}

test "markdown renderer preserves text after a list" {
    const html = try renderAlloc(std.testing.allocator, "- item\nA paragraph");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<ul><li>item</li></ul><p>A paragraph</p>", html);
}
