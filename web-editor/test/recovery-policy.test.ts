import { expect, test } from "vitest";
import { createDocument } from "../src/model";
import { makeSnapshot } from "../src/recovery";
import { classifyRecovery, conflictsWithServer, mergeDocuments } from "../src/recovery-policy";

const scope = { siteNamespace: "https://verso.example", ownerScope: "account:42" };

test("non-current snapshots require explicit recovery consent", () => {
  const current = makeSnapshot(scope, createDocument({ clientDraftId: "current" }), 2);
  const other = makeSnapshot(scope, createDocument({ clientDraftId: "other", title: "Recover me" }), 3);
  expect(classifyRecovery([current, other], "current")).toEqual([{ snapshot: other, reason: "non-current", requiresConsent: true }]);
});

test("server revision conflicts are classified separately", () => {
  const local = makeSnapshot(scope, createDocument({ clientDraftId: "local", title: "Local" }), 5);
  const server = { document: createDocument({ clientDraftId: "local", title: "Server" }), workingRevision: 2, updatedAt: 4 };
  expect(conflictsWithServer(local, server)).toBe(true);
  expect(classifyRecovery([local], "local", server)[0]?.reason).toBe("server-conflict");
});

test("merge preserves persisted sections and adds local-only sections", () => {
  const persisted = createDocument({ clientDraftId: "draft", title: "Server", sections: [{ kind: "text", id: "server-section", markdown: "server" }] });
  const local = createDocument({ clientDraftId: "draft", title: "Local", sections: [{ kind: "text", id: "local-section", markdown: "local" }] });
  const merged = mergeDocuments(local, persisted);
  expect(merged.title).toBe("Local");
  expect(merged.sections.map((section) => section.id)).toEqual(["server-section", "local-section"]);
});
