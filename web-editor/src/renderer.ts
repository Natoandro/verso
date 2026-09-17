import type { EditorDocument, ImageSection, Section, TextSection } from "./model";

const unsafeUrlCharacters = /[\u0000-\u0020\u007f<>"']/;
const schemePattern = /^[a-z][a-z0-9+.-]*:/i;

export function escapeHtml(value: unknown): string {
  return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

export function safeUrl(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const url = value.trim();
  if (!url || unsafeUrlCharacters.test(url) || url.startsWith("//")) return null;
  if (!schemePattern.test(url)) return url;
  return /^(https?:|mailto:)/i.test(url) ? url : null;
}

function renderInline(source: string): string {
  let html = "";
  let cursor = 0;
  while (cursor < source.length) {
    const remaining = source.slice(cursor);
    let match = remaining.match(/^`([^`\n]+)`/);
    if (match) {
      html += `<code>${escapeHtml(match[1])}</code>`;
      cursor += match[0].length;
      continue;
    }
    match = remaining.match(/^!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)/);
    if (match) {
      const url = safeUrl(match[2]);
      html += url ? `<img src="${escapeHtml(url)}" alt="${escapeHtml(match[1])}" loading="lazy">` : escapeHtml(match[0]);
      cursor += match[0].length;
      continue;
    }
    match = remaining.match(/^\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)/);
    if (match) {
      const url = safeUrl(match[2]);
      html += url ? `<a href="${escapeHtml(url)}">${renderInline(match[1])}</a>` : escapeHtml(match[0]);
      cursor += match[0].length;
      continue;
    }
    match = remaining.match(/^\*\*([^*\n]+)\*\*|^__([^_\n]+)__|^\*([^*\n]+)\*|^_([^_\n]+)_/);
    if (match) {
      const content = match[1] || match[2] || match[3] || match[4];
      const tag = match[1] || match[2] ? "strong" : "em";
      html += `<${tag}>${renderInline(content)}</${tag}>`;
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

function isBlockStart(line: string): boolean {
  return /^```/.test(line) || /^(#{1,6})\s+/.test(line) || /^>\s?/.test(line) || /^\s*[-*+]\s+/.test(line) || /^\s*\d+\.\s+/.test(line);
}

export function renderMarkdown(source: unknown): string {
  if (typeof source !== "string" || source.length === 0) return "";
  const lines = source.replace(/\r\n?/g, "\n").split("\n");
  const blocks: string[] = [];
  let index = 0;
  while (index < lines.length) {
    if (!lines[index].trim()) {
      index += 1;
      continue;
    }
    if (/^```/.test(lines[index])) {
      index += 1;
      const code: string[] = [];
      while (index < lines.length && !/^```\s*$/.test(lines[index])) code.push(lines[index++]);
      if (index < lines.length) index += 1;
      blocks.push(`<pre><code>${escapeHtml(code.join("\n"))}</code></pre>`);
      continue;
    }
    const heading = lines[index].match(/^(#{1,6})\s+(.+?)\s*#*$/);
    if (heading) {
      const level = heading[1].length;
      blocks.push(`<h${level}>${renderInline(heading[2])}</h${level}>`);
      index += 1;
      continue;
    }
    if (/^>\s?/.test(lines[index])) {
      const quote: string[] = [];
      while (index < lines.length && /^>\s?/.test(lines[index])) quote.push(lines[index++].replace(/^>\s?/, ""));
      blocks.push(`<blockquote>${renderMarkdown(quote.join("\n"))}</blockquote>`);
      continue;
    }
    const unordered = lines[index].match(/^\s*[-*+]\s+(.+)$/);
    const ordered = lines[index].match(/^\s*\d+\.\s+(.+)$/);
    if (unordered || ordered) {
      const orderedList = Boolean(ordered);
      const items: string[] = [];
      while (index < lines.length) {
        const item = lines[index].match(orderedList ? /^\s*\d+\.\s+(.+)$/ : /^\s*[-*+]\s+(.+)$/);
        if (!item) break;
        items.push(`<li>${renderInline(item[1])}</li>`);
        index += 1;
      }
      const tag = orderedList ? "ol" : "ul";
      blocks.push(`<${tag}>${items.join("")}</${tag}>`);
      continue;
    }
    const paragraph: string[] = [];
    while (index < lines.length && lines[index].trim() && !isBlockStart(lines[index])) paragraph.push(lines[index++]);
    if (paragraph.length === 0) paragraph.push(lines[index++]);
    blocks.push(`<p>${paragraph.map(renderInline).join("<br>")}</p>`);
  }
  return blocks.join("");
}

export function renderSection(section: unknown): string {
  if (!section || typeof section !== "object") return "";
  const candidate = section as Partial<Section>;
  if (candidate.kind === "text") return renderMarkdown((candidate as Partial<TextSection>).markdown);
  if (candidate.kind !== "image") return "";
  const image = candidate as Partial<ImageSection>;
  return `<figure class="preview-image-placeholder"><div>Image placeholder</div>${image.alt ? `<p>Alt text: ${escapeHtml(image.alt)}</p>` : ""}${image.caption ? `<figcaption>${escapeHtml(image.caption)}</figcaption>` : ""}</figure>`;
}

export function renderDocument(document: unknown): string {
  if (!document || typeof document !== "object") return "";
  const candidate = document as Partial<EditorDocument>;
  const blocks: string[] = [];
  if (typeof candidate.title === "string" && candidate.title.trim()) blocks.push(`<h1>${escapeHtml(candidate.title)}</h1>`);
  if (typeof candidate.description === "string" && candidate.description.trim()) blocks.push(`<p class="preview-description">${escapeHtml(candidate.description)}</p>`);
  if (!Array.isArray(candidate.sections)) return blocks.join("");
  candidate.sections.forEach((section) => {
    const rendered = renderSection(section);
    if (rendered) blocks.push(rendered);
  });
  return blocks.join("");
}

export type PreviewResult = { applied: boolean; html: string | null };
export type PreviewRenderer<T> = {
  request(document: T, onRender?: (html: string) => void): Promise<PreviewResult>;
  cancel(): void;
};

export function createPreviewRenderer<T>(options: { renderDocument?: (document: T) => string; enqueue?: (work: () => string) => Promise<string> } = {}): PreviewRenderer<T> {
  const render = options.renderDocument || ((document) => renderDocument(document as EditorDocument));
  const enqueue = options.enqueue || ((work) => Promise.resolve().then(work));
  let generation = 0;
  return {
    request(document, onRender) {
      const requestedGeneration = ++generation;
      return Promise.resolve(enqueue(() => render(document))).then((html) => {
        if (requestedGeneration !== generation) return { applied: false, html: null };
        onRender?.(html);
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
