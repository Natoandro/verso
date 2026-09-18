import { expect, test } from "vitest";
import { createDocument } from "../src/model";
import { createLocalStorageStore, makeSnapshot, type RecoveryScope } from "../src/recovery";

class MemoryStorage implements Storage {
  private values = new Map<string, string>();

  get length(): number { return this.values.size; }
  clear(): void { this.values.clear(); }
  getItem(key: string): string | null { return this.values.get(key) ?? null; }
  key(index: number): string | null { return [...this.values.keys()][index] ?? null; }
  removeItem(key: string): void { this.values.delete(key); }
  setItem(key: string, value: string): void { this.values.set(key, value); }
}

const scope: RecoveryScope = { siteNamespace: "https://verso.example", ownerScope: "anonymous" };

function snapshot(draftId: string, title: string, updatedAt: number, customScope = scope) {
  return makeSnapshot(customScope, createDocument({ clientDraftId: draftId, title }, () => `${draftId}-section`), updatedAt);
}

test("fallback snapshots are isolated by site, owner, and draft identity", async () => {
  const storage = new MemoryStorage();
  const store = createLocalStorageStore(storage);
  await store.save(snapshot("draft-one", "Anonymous draft", 1));
  await store.save(snapshot("draft-one", "Other site", 2, { ...scope, siteNamespace: "https://other.example" }));
  await store.save(snapshot("draft-one", "Signed in", 3, { ...scope, ownerScope: "account:42" }));

  expect((await store.list(scope)).map((item) => item.document.title)).toEqual(["Anonymous draft"]);
  expect((await store.get({ ...scope, ownerScope: "account:42" }, "draft-one"))?.document.title).toBe("Signed in");
  expect(await store.get(scope, "missing")).toBeNull();
});

test("fallback storage is bounded and retains the newest entries", async () => {
  const storage = new MemoryStorage();
  const store = createLocalStorageStore(storage, { maximumEntries: 2 });
  await store.save(snapshot("draft-one", "One", 1));
  await store.save(snapshot("draft-two", "Two", 2));
  await store.save(snapshot("draft-three", "Three", 3));

  expect((await store.list(scope)).map((item) => item.draftId)).toEqual(["draft-three", "draft-two"]);
  expect(await store.get(scope, "draft-one")).toBeNull();
});

test("malformed fallback values are ignored instead of becoming editor state", async () => {
  const storage = new MemoryStorage();
  const store = createLocalStorageStore(storage);
  storage.setItem("verso:editor-recovery:1:bad", JSON.stringify({ schemaVersion: 1, draftId: "bad" }));
  expect(await store.list(scope)).toEqual([]);
});

test("snapshots retain server lineage metadata without making it canonical", () => {
  const document = createDocument({ clientDraftId: "draft-lineage", serverDocumentId: "document-1", baseServerVersion: 3, workingRevision: 7 });
  const saved = makeSnapshot(scope, document, 9);
  expect(saved.serverDocumentId).toBe("document-1");
  expect(saved.baseServerVersion).toBe(3);
  expect(saved.workingRevision).toBe(7);
  expect(saved.document.clientDraftId).toBe("draft-lineage");
});

test("snapshots accept reactive proxy documents", () => {
  const document = createDocument({ clientDraftId: "draft-proxy", title: "Proxy draft" });
  const reactiveDocument = new Proxy(document, {});
  expect(makeSnapshot(scope, reactiveDocument).document.title).toBe("Proxy draft");
});

test("snapshots retain editor presentation state", () => {
  const saved = makeSnapshot(scope, createDocument({ clientDraftId: "draft-presentation" }), 10, {
    titleMode: "preview",
    detailsOpen: true,
    activeSectionId: "section-1",
    sectionModes: [{ id: "section-1", mode: "preview" }],
  });
  expect(saved.presentation).toEqual({
    titleMode: "preview",
    detailsOpen: true,
    activeSectionId: "section-1",
    sectionModes: [{ id: "section-1", mode: "preview" }],
  });
});
