import { expect, test } from "vitest";
import { draftScopedUrl, ensureDraftScopedUrl, isDraftId, readDraftId } from "../src/draft-route";

test("draft URLs preserve the editor route and unrelated query state", () => {
  const href = "https://verso.example/admin/editor?tab=compose#title";
  expect(draftScopedUrl("draft-one", href)).toBe("/admin/editor?tab=compose&draft=draft-one#title");
  expect(readDraftId({ href: `https://verso.example${draftScopedUrl("draft-one", href)}` })).toBe("draft-one");
  expect(isDraftId("draft-one")).toBe(true);
  expect(isDraftId("\nunsafe")).toBe(false);
});

test("unscoped editor navigation gets a stable current-history draft URL", () => {
  const location = { href: "https://verso.example/admin/editor?tab=compose" };
  let replacement: string | null = null;
  const history = { replaceState: (_state: unknown, _title: string, url?: string | URL | null) => { replacement = String(url); } };
  expect(ensureDraftScopedUrl("draft-one", location, history)).toBe(true);
  expect(replacement).toBe("/admin/editor?tab=compose&draft=draft-one");
  expect(ensureDraftScopedUrl("draft-one", { href: `https://verso.example${replacement}` }, history)).toBe(false);
});
