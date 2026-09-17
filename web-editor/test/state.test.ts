import { expect, test } from "vitest";
import { createEditorState, reduceEditorState } from "../src/state";

test("the reducer keeps editing, preview, and presentation transitions explicit", () => {
  let next = 0;
  const idFactory = () => `local-${++next}`;
  let state = createEditorState({ sections: [] }, idFactory);
  state = reduceEditorState(state, { type: "add-section", kind: "text" }, idFactory);
  const id = state.document.sections[0].id;
  expect(state.activeSectionId).toBe(id);
  state = reduceEditorState(state, { type: "update-section", id, changes: { markdown: "# Draft" } }, idFactory);
  expect(state.sectionModes.get(id)).toBe("edit");
  state = reduceEditorState(state, { type: "set-section-preview", id, html: "<h1>Draft</h1>" }, idFactory);
  expect(state.sectionModes.get(id)).toBe("preview");
  state = reduceEditorState(state, { type: "invalidate-section", id }, idFactory);
  expect(state.sectionModes.get(id)).toBe("edit");
  expect(state.sectionPreviewHtml.has(id)).toBe(false);
});
