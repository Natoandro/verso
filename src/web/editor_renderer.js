(function (root, factory) {
    const renderer = factory();
    if (typeof module !== "undefined" && module.exports) module.exports = renderer;
    if (root) root.VersoEditorRenderer = renderer;
})(typeof globalThis === "undefined" ? this : globalThis, function () {
    "use strict";

    const unsafeUrlCharacters = /[\u0000-\u0020\u007f<>"']/;
    const schemePattern = /^[a-z][a-z0-9+.-]*:/i;

    function escapeHtml(value) {
        return String(value)
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#39;");
    }

    function safeUrl(value) {
        if (typeof value !== "string") return null;
        const url = value.trim();
        if (!url || unsafeUrlCharacters.test(url) || url.startsWith("//")) return null;
        if (!schemePattern.test(url)) return url;
        return /^(https?:|mailto:)/i.test(url) ? url : null;
    }

    function renderInline(source) {
        let html = "";
        let cursor = 0;
        while (cursor < source.length) {
            const remaining = source.slice(cursor);
            let match = remaining.match(/^`([^`\n]+)`/);
            if (match) {
                html += "<code>" + escapeHtml(match[1]) + "</code>";
                cursor += match[0].length;
                continue;
            }

            match = remaining.match(/^!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)/);
            if (match) {
                const url = safeUrl(match[2]);
                if (url) {
                    html += "<img src=\"" + escapeHtml(url) + "\" alt=\"" + escapeHtml(match[1]) + "\" loading=\"lazy\">";
                } else {
                    html += escapeHtml(match[0]);
                }
                cursor += match[0].length;
                continue;
            }

            match = remaining.match(/^\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)/);
            if (match) {
                const url = safeUrl(match[2]);
                if (url) {
                    html += "<a href=\"" + escapeHtml(url) + "\">" + renderInline(match[1]) + "</a>";
                } else {
                    html += escapeHtml(match[0]);
                }
                cursor += match[0].length;
                continue;
            }

            match = remaining.match(/^\*\*([^*\n]+)\*\*|^__([^_\n]+)__|^\*([^*\n]+)\*|^_([^_\n]+)_/);
            if (match) {
                const content = match[1] || match[2] || match[3] || match[4];
                const tag = match[1] || match[2] ? "strong" : "em";
                html += "<" + tag + ">" + renderInline(content) + "</" + tag + ">";
                cursor += match[0].length;
                continue;
            }

            let textEnd = cursor + 1;
            while (textEnd < source.length && !/[`!\[*_]/.test(source[textEnd])) textEnd += 1;
            html += escapeHtml(source.slice(cursor, textEnd));
            cursor = textEnd;
        }
        return html;
    }

    function isBlockStart(line) {
        return /^```/.test(line) || /^(#{1,6})\s+/.test(line) || /^>\s?/.test(line) ||
            /^\s*[-*+]\s+/.test(line) || /^\s*\d+\.\s+/.test(line);
    }

    function renderMarkdown(source) {
        if (typeof source !== "string" || source.length === 0) return "";
        const lines = source.replace(/\r\n?/g, "\n").split("\n");
        const blocks = [];
        let index = 0;
        while (index < lines.length) {
            if (!lines[index].trim()) {
                index += 1;
                continue;
            }

            if (/^```/.test(lines[index])) {
                index += 1;
                const code = [];
                while (index < lines.length && !/^```\s*$/.test(lines[index])) {
                    code.push(lines[index]);
                    index += 1;
                }
                if (index < lines.length) index += 1;
                blocks.push("<pre><code>" + escapeHtml(code.join("\n")) + "</code></pre>");
                continue;
            }

            const heading = lines[index].match(/^(#{1,6})\s+(.+?)\s*#*$/);
            if (heading) {
                const level = heading[1].length;
                blocks.push("<h" + level + ">" + renderInline(heading[2]) + "</h" + level + ">");
                index += 1;
                continue;
            }

            if (/^>\s?/.test(lines[index])) {
                const quote = [];
                while (index < lines.length && /^>\s?/.test(lines[index])) {
                    quote.push(lines[index].replace(/^>\s?/, ""));
                    index += 1;
                }
                blocks.push("<blockquote>" + renderMarkdown(quote.join("\n")) + "</blockquote>");
                continue;
            }

            const unordered = lines[index].match(/^\s*[-*+]\s+(.+)$/);
            const ordered = lines[index].match(/^\s*\d+\.\s+(.+)$/);
            if (unordered || ordered) {
                const orderedList = Boolean(ordered);
                const items = [];
                while (index < lines.length) {
                    const item = lines[index].match(orderedList ? /^\s*\d+\.\s+(.+)$/ : /^\s*[-*+]\s+(.+)$/);
                    if (!item) break;
                    items.push("<li>" + renderInline(item[1]) + "</li>");
                    index += 1;
                }
                const tag = orderedList ? "ol" : "ul";
                blocks.push("<" + tag + ">" + items.join("") + "</" + tag + ">");
                continue;
            }

            const paragraph = [];
            while (index < lines.length && lines[index].trim() && !isBlockStart(lines[index])) {
                paragraph.push(lines[index]);
                index += 1;
            }
            if (paragraph.length === 0) {
                paragraph.push(lines[index]);
                index += 1;
            }
            blocks.push("<p>" + paragraph.map(renderInline).join("<br>") + "</p>");
        }
        return blocks.join("");
    }

    function renderDocument(document) {
        if (!document || typeof document !== "object") return "";
        const blocks = [];
        if (typeof document.title === "string" && document.title.trim()) {
            blocks.push("<h1>" + escapeHtml(document.title) + "</h1>");
        }
        if (typeof document.description === "string" && document.description.trim()) {
            blocks.push("<p class=\"preview-description\">" + escapeHtml(document.description) + "</p>");
        }
        if (Array.isArray(document.sections)) {
            document.sections.forEach((section) => {
                const rendered = renderSection(section);
                if (rendered) blocks.push(rendered);
            });
        }
        return blocks.join("");
    }

    function renderSection(section) {
        if (!section || typeof section !== "object") return "";
        if (section.kind === "text") {
            return "<section class=\"preview-text-section\">" + renderMarkdown(section.markdown) + "</section>";
        }
        if (section.kind === "image") {
            const alt = typeof section.alt === "string" ? section.alt : "";
            const caption = typeof section.caption === "string" ? section.caption : "";
            return "<figure class=\"preview-image-placeholder\"><div>Image placeholder</div>" +
                (alt ? "<p>Alt text: " + escapeHtml(alt) + "</p>" : "") +
                (caption ? "<figcaption>" + escapeHtml(caption) + "</figcaption>" : "") + "</figure>";
        }
        return "";
    }

    function createPreviewRenderer(options) {
        options = options || {};
        const render = options.renderDocument || renderDocument;
        const enqueue = options.enqueue || ((work) => Promise.resolve().then(work));
        let generation = 0;

        return {
            request(document, onRender) {
                const requestedGeneration = ++generation;
                return Promise.resolve(enqueue(() => render(document))).then((html) => {
                    if (requestedGeneration !== generation) return { applied: false, html: null };
                    if (typeof onRender === "function") onRender(html);
                    return { applied: true, html };
                }, (error) => {
                    if (requestedGeneration !== generation) return { applied: false, html: null };
                    throw error;
                });
            },
            cancel() {
                generation += 1;
            },
        };
    }

    return { escapeHtml, safeUrl, renderMarkdown, renderSection, renderDocument, createPreviewRenderer };
});
