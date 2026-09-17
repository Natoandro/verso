const assert = require("node:assert/strict");
const test = require("node:test");
const renderer = require("../src/web/editor_renderer.js");

test("restricted Markdown escapes raw HTML and renders supported blocks", () => {
    const html = renderer.renderMarkdown("# Hello\n\nA **strong** word and `code`.\n\n- one\n- two\n\n> quoted");
    assert.match(html, /<h1>Hello<\/h1>/);
    assert.match(html, /<strong>strong<\/strong>/);
    assert.match(html, /<code>code<\/code>/);
    assert.match(html, /<ul><li>one<\/li><li>two<\/li><\/ul>/);
    assert.match(html, /<blockquote><p>quoted<\/p><\/blockquote>/);
    assert.doesNotMatch(html, /<script/);
});

test("raw HTML is emitted only as escaped text", () => {
    const html = renderer.renderMarkdown('<img src=x onerror="alert(1)"> <b>unsafe</b>');
    assert.match(html, /&lt;img src=x onerror=&quot;alert\(1\)&quot;&gt;/);
    assert.match(html, /&lt;b&gt;unsafe&lt;\/b&gt;/);
    assert.doesNotMatch(html, /<img/);
});

test("safe links are rendered and unsafe URLs stay text", () => {
    const html = renderer.renderMarkdown("[safe](https://example.test/a) [relative](/docs) [bad](javascript:alert(1)) [asset](assets://diagram)");
    assert.match(html, /<a href="https:\/\/example\.test\/a">safe<\/a>/);
    assert.match(html, /<a href="\/docs">relative<\/a>/);
    assert.match(html, /\[bad\]\(javascript:alert\(1\)\)/);
    assert.match(html, /\[asset\]\(assets:\/\/diagram\)/);
    assert.doesNotMatch(html, /<a href="javascript:/i);
});

test("malformed input does not throw or create executable markup", () => {
    assert.equal(renderer.renderMarkdown(null), "");
    const html = renderer.renderMarkdown("[unfinished\n```\n<em>code</em>");
    assert.match(html, /\[unfinished/);
    assert.match(html, /&lt;em&gt;code&lt;\/em&gt;/);
    assert.doesNotMatch(html, /<em>/);
});

test("out-of-order preview results cannot replace the latest generation", async () => {
    const pending = [];
    const preview = renderer.createPreviewRenderer({
        renderDocument: (document) => document.value,
        enqueue: (work) => new Promise((resolve) => pending.push(() => resolve(work()))),
    });
    const applied = [];
    const first = preview.request({ value: "old" }, (html) => applied.push(html));
    const second = preview.request({ value: "new" }, (html) => applied.push(html));
    pending[1]();
    assert.deepEqual(await second, { applied: true, html: "new" });
    pending[0]();
    assert.deepEqual(await first, { applied: false, html: null });
    assert.deepEqual(applied, ["new"]);
});

test("a stale preview failure cannot replace a newer successful result", async () => {
    const pending = [];
    const preview = renderer.createPreviewRenderer({
        renderDocument: (document) => document.value,
        enqueue: (work) => new Promise((resolve, reject) => pending.push({ work, resolve, reject })),
    });
    const applied = [];
    const first = preview.request({ value: "old" }, (html) => applied.push(html));
    const second = preview.request({ value: "new" }, (html) => applied.push(html));
    pending[1].resolve(pending[1].work());
    assert.deepEqual(await second, { applied: true, html: "new" });
    pending[0].reject(new Error("stale failure"));
    assert.deepEqual(await first, { applied: false, html: null });
    assert.deepEqual(applied, ["new"]);
});
