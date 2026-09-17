const assert = require("node:assert/strict");
const test = require("node:test");
const model = require("../src/web/editor_model.js");

function ids() {
    let next = 0;
    return () => "section-" + (++next);
}

test("section lifecycle operations are deterministic and immutable", () => {
    const nextId = ids();
    let document = model.createDocument({ title: "Draft" }, nextId);
    assert.equal(document.clientDraftId, "section-1");
    document = model.insertSection(document, 0, { kind: "text", markdown: "first" }, nextId);
    document = model.insertSection(document, 1, { kind: "image", alt: "Diagram" }, nextId);
    const original = document;
    const firstId = document.sections[0].id;
    const imageId = document.sections[1].id;

    document = model.duplicateSection(document, firstId, 1, nextId);
    assert.deepEqual(document.sections.map((section) => section.kind), ["text", "text", "image"]);
    assert.notEqual(document.sections[0].id, document.sections[1].id);
    document = model.moveSection(document, imageId, 0);
    document = model.updateSection(document, imageId, { alt: "Updated diagram" }, nextId);
    document = model.deleteSection(document, firstId);

    assert.deepEqual(document.sections.map((section) => section.kind), ["image", "text"]);
    assert.equal(document.sections[0].alt, "Updated diagram");
    assert.equal(original.sections.length, 2);
    assert.equal(original.sections[1].alt, "Diagram");
});

test("invalid positions and unknown sections are rejected", () => {
    const nextId = ids();
    const document = model.createDocument({ sections: [{ kind: "text", markdown: "" }] }, nextId);
    assert.throws(() => model.insertSection(document, 2, { kind: "text" }, nextId), RangeError);
    assert.throws(() => model.moveSection(document, "missing", 0), Error);
    assert.throws(() => model.deleteSection(document, "missing"), Error);
});
