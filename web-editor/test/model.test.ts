import { describe, expect, test } from "vitest";
import { createDocument, deleteSection, duplicateSection, insertSection, moveSection, updateSection } from "../src/model";

function ids() {
  let next = 0;
  return () => `section-${++next}`;
}

test("section lifecycle operations are deterministic and immutable", () => {
  const nextId = ids();
  let document = createDocument({ title: "Draft" }, nextId);
  expect(document.clientDraftId).toBe("section-1");
  document = insertSection(document, 0, { kind: "text", markdown: "first" }, nextId);
  document = insertSection(document, 1, { kind: "image", alt: "Diagram" }, nextId);
  const original = document;
  const firstId = document.sections[0].id;
  const imageId = document.sections[1].id;
  document = duplicateSection(document, firstId, 1, nextId);
  expect(document.sections.map((section) => section.kind)).toEqual(["text", "text", "image"]);
  expect(document.sections[0].id).not.toBe(document.sections[1].id);
  document = moveSection(document, imageId, 0);
  document = updateSection(document, imageId, { alt: "Updated diagram" }, nextId);
  document = deleteSection(document, firstId);
  expect(document.sections.map((section) => section.kind)).toEqual(["image", "text"]);
  expect(document.sections[0].kind === "image" && document.sections[0].alt).toBe("Updated diagram");
  expect(original.sections).toHaveLength(2);
  expect(original.sections[1].kind === "image" && original.sections[1].alt).toBe("Diagram");
});

test("invalid positions and unknown sections are rejected", () => {
  const nextId = ids();
  const document = createDocument({ sections: [{ kind: "text", markdown: "" }] }, nextId);
  expect(() => insertSection(document, 2, { kind: "text" }, nextId)).toThrow(RangeError);
  expect(() => moveSection(document, "missing", 0)).toThrow(Error);
  expect(() => deleteSection(document, "missing")).toThrow(Error);
});

test("section insertion never creates a duplicate keyed id", () => {
  let calls = 0;
  const nextId = () => `section-${++calls}`;
  const document = createDocument({ clientDraftId: "draft", sections: [{ kind: "text", id: "section-1" }] }, nextId);
  const next = insertSection(document, 1, { kind: "text" }, nextId);
  expect(next.sections.map((section) => section.id)).toEqual(["section-1", "section-2"]);
});
