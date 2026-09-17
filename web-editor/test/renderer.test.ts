import { describe, expect, test } from "vitest";
import { createPreviewRenderer, renderDocument, renderMarkdown, renderSection } from "../src/renderer";

test("restricted Markdown escapes raw HTML and renders supported blocks", () => {
  const html = renderMarkdown("# Hello\n\nA **strong** word and `code`.\n\n- one\n- two\n\n> quoted");
  expect(html).toMatch(/<h1>Hello<\/h1>/);
  expect(html).toMatch(/<strong>strong<\/strong>/);
  expect(html).toMatch(/<code>code<\/code>/);
  expect(html).toMatch(/<ul><li>one<\/li><li>two<\/li><\/ul>/);
  expect(html).toMatch(/<blockquote><p>quoted<\/p><\/blockquote>/);
  expect(html).not.toMatch(/<script/);
});

test("raw HTML is emitted only as escaped text", () => {
  const html = renderMarkdown('<img src=x onerror="alert(1)"> <b>unsafe</b>');
  expect(html).toMatch(/&lt;img src=x onerror=&quot;alert\(1\)&quot;&gt;/);
  expect(html).toMatch(/&lt;b&gt;unsafe&lt;\/b&gt;/);
  expect(html).not.toMatch(/<img/);
});

test("safe links are rendered and unsafe URLs stay text", () => {
  const html = renderMarkdown("[safe](https://example.test/a) [relative](/docs) [bad](javascript:alert(1)) [asset](assets://diagram)");
  expect(html).toMatch(/<a href="https:\/\/example\.test\/a">safe<\/a>/);
  expect(html).toMatch(/<a href="\/docs">relative<\/a>/);
  expect(html).toMatch(/\[bad\]\(javascript:alert\(1\)\)/);
  expect(html).toMatch(/\[asset\]\(assets:\/\/diagram\)/);
  expect(html).not.toMatch(/<a href="javascript:/i);
});

test("malformed input does not throw or create executable markup", () => {
  expect(renderMarkdown(null)).toBe("");
  const html = renderMarkdown("[unfinished\n```\n<em>code</em>");
  expect(html).toMatch(/\[unfinished/);
  expect(html).toMatch(/&lt;em&gt;code&lt;\/em&gt;/);
  expect(html).not.toMatch(/<em>/);
});

test("malformed documents and unknown sections render as empty safe output", () => {
  expect(renderSection(null)).toBe("");
  expect(renderSection({ kind: "unsupported" })).toBe("");
  expect(renderSection({ kind: "text" })).toBe("");
  expect(renderDocument({ title: "Title", sections: "not-an-array" })).toBe("<h1>Title</h1>");
});

test("section rendering keeps image placeholders and metadata escaped", () => {
  const html = renderSection({ kind: "image", id: "one", asset: "", display: "inline", alt: '<script>alert("x")</script>', caption: "A caption" });
  expect(html).toMatch(/Image placeholder/);
  expect(html).toMatch(/&lt;script&gt;alert\(&quot;x&quot;\)&lt;\/script&gt;/);
  expect(html).toMatch(/<figcaption>A caption<\/figcaption>/);
  expect(html).not.toMatch(/<script>/);
});

test("out-of-order preview results cannot replace the latest generation", async () => {
  const pending: Array<() => void> = [];
  const preview = createPreviewRenderer({ renderDocument: (document: { value: string }) => document.value, enqueue: (work) => new Promise((resolve) => pending.push(() => resolve(work()))) });
  const applied: string[] = [];
  const first = preview.request({ value: "old" }, (html) => applied.push(html));
  const second = preview.request({ value: "new" }, (html) => applied.push(html));
  pending[1]();
  await expect(second).resolves.toEqual({ applied: true, html: "new" });
  pending[0]();
  await expect(first).resolves.toEqual({ applied: false, html: null });
  expect(applied).toEqual(["new"]);
});

test("a stale preview failure cannot replace a newer successful result", async () => {
  const pending: Array<{ work: () => string; resolve: (value: string) => void; reject: (error: Error) => void }> = [];
  const preview = createPreviewRenderer({
    renderDocument: (document: { value: string }) => document.value,
    enqueue: (work) => new Promise<string>((resolve, reject) => pending.push({ work, resolve, reject })),
  });
  const applied: string[] = [];
  const first = preview.request({ value: "old" }, (html) => applied.push(html));
  const second = preview.request({ value: "new" }, (html) => applied.push(html));
  pending[1].resolve(pending[1].work());
  await expect(second).resolves.toEqual({ applied: true, html: "new" });
  pending[0].reject(new Error("stale failure"));
  await expect(first).resolves.toEqual({ applied: false, html: null });
  expect(applied).toEqual(["new"]);
});
