import { expect, test } from "vitest";
import { createDocument } from "../src/model";
import { createDocumentTransport, DocumentTransportError } from "../src/transport";

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

const serverDraft = {
  document_id: 42,
  version_id: 7,
  version_number: 1,
  revision_number: 3,
  document_type: "article",
  title: "Persisted draft",
  slug: "persisted-draft",
  description: null,
  sections: [{ id: 11, kind: "text", markdown: "Saved" }],
};

test("transport maps server identity and sections into the client model", async () => {
  const requests: RequestInit[] = [];
  const transport = createDocumentTransport(async (_input, init) => {
    requests.push(init || {});
    return response(serverDraft);
  });
  const draft = await transport.loadDraft("42");
  expect(draft.document.serverDocumentId).toBe("42");
  expect(draft.document.serverVersionId).toBe("7");
  expect(draft.document.workingRevision).toBe(3);
  expect(draft.document.sections).toEqual([{ id: "11", kind: "text", markdown: "Saved" }]);
  expect(requests[0]?.credentials).toBe("same-origin");
});

test("save sends the expected revision and rejects stale writes without changing local state", async () => {
  let body = "";
  const transport = createDocumentTransport(async (_input, init) => {
    body = String(init?.body);
    return response({ code: "stale_revision", message: "Draft changed" }, 409);
  });
  const document = createDocument({
    clientDraftId: "local",
    serverDocumentId: "42",
    serverVersionId: "7",
    workingRevision: 3,
    title: "Draft",
    slug: "draft",
  });
  await expect(transport.saveDraft(document)).rejects.toMatchObject({ status: 409, stale: true });
  expect(JSON.parse(body)).toMatchObject({ document_id: "42", version_id: "7", expected_revision: 3 });
});

test("transport exposes unauthorized failures for the protected boundary", async () => {
  const transport = createDocumentTransport(async () => response({ code: "unauthorized", message: "Sign in" }, 401));
  await expect(transport.listDocuments()).rejects.toBeInstanceOf(DocumentTransportError);
  await expect(transport.listDocuments()).rejects.toMatchObject({ status: 401, code: "unauthorized", stale: false });
});
