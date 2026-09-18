import { createDocument, type EditorDocument, type Section } from "./model";

export type DocumentSummary = {
  documentId: string;
  documentType: string;
  title: string;
  slug: string;
  versionId: string;
  versionNumber: number;
  workingRevision: number;
  updatedAt?: string;
};

export type ServerDraft = {
  document: EditorDocument;
  documentId: string;
  versionId: string;
  versionNumber: number;
  workingRevision: number;
  updatedAt?: string;
};

export type CreateDraftInput = {
  documentType?: string;
  title: string;
  slug: string;
  description?: string;
  language?: string;
};

export type SaveDraftResult = {
  documentId: string;
  versionId: string;
  versionNumber: number;
  workingRevision: number;
};

export class DocumentTransportError extends Error {
  readonly status: number;
  readonly code?: string;
  readonly stale: boolean;

  constructor(message: string, status: number, code?: string) {
    super(message);
    this.name = "DocumentTransportError";
    this.status = status;
    this.code = code;
    this.stale = status === 409 || code === "stale_revision";
  }
}

export type DocumentTransport = {
  listDocuments(): Promise<DocumentSummary[]>;
  createDraft(input: CreateDraftInput): Promise<ServerDraft>;
  loadDraft(documentId: string): Promise<ServerDraft>;
  saveDraft(document: EditorDocument): Promise<SaveDraftResult>;
};

type JsonRecord = Record<string, unknown>;

function requiredString(record: JsonRecord, ...keys: string[]): string {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" && value.length > 0) return value;
    if (typeof value === "number" && Number.isSafeInteger(value)) return String(value);
  }
  throw new DocumentTransportError(`Response is missing ${keys[0]}`, 502, "invalid_response");
}

function requiredNumber(record: JsonRecord, ...keys: string[]): number {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return value;
  }
  throw new DocumentTransportError(`Response is missing ${keys[0]}`, 502, "invalid_response");
}

function optionalString(record: JsonRecord, ...keys: string[]): string | undefined {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string") return value;
  }
  return undefined;
}

function sectionFromWire(value: unknown): Section {
  if (!value || typeof value !== "object") throw new DocumentTransportError("Invalid section response", 502, "invalid_response");
  const section = value as JsonRecord;
  const id = requiredString(section, "id", "section_id");
  const kind = section.kind;
  if (kind === "text") {
    const markdown = section.markdown;
    if (typeof markdown !== "string") throw new DocumentTransportError("Invalid text section response", 502, "invalid_response");
    return { id, kind, markdown };
  }
  if (kind === "image") {
    const asset = section.asset;
    const alt = section.alt;
    const caption = section.caption;
    const display = section.display;
    if (typeof asset !== "string" || typeof alt !== "string" || typeof caption !== "string" || typeof display !== "string") {
      throw new DocumentTransportError("Invalid image section response", 502, "invalid_response");
    }
    return { id, kind, asset, alt, caption, display };
  }
  throw new DocumentTransportError("Unsupported section response", 502, "invalid_response");
}

function draftFromWire(value: unknown): ServerDraft {
  if (!value || typeof value !== "object") throw new DocumentTransportError("Invalid draft response", 502, "invalid_response");
  const record = value as JsonRecord;
  const documentId = requiredString(record, "document_id", "documentId");
  const versionId = requiredString(record, "version_id", "versionId");
  const versionNumber = requiredNumber(record, "version_number", "versionNumber");
  const workingRevision = requiredNumber(record, "revision_number", "working_revision", "workingRevision");
  const sections = record.sections;
  if (!Array.isArray(sections)) throw new DocumentTransportError("Draft response is missing sections", 502, "invalid_response");
  const document = createDocument({
    clientDraftId: `server-${documentId}-${versionId}`,
    serverDocumentId: documentId,
    serverVersionId: versionId,
    serverVersionNumber: versionNumber,
    baseServerVersion: versionNumber,
    workingRevision,
    documentType: requiredString(record, "document_type", "documentType", "type"),
    title: requiredString(record, "title"),
    slug: requiredString(record, "slug"),
    description: optionalString(record, "description") || "",
    sections: sections.map(sectionFromWire),
  });
  return {
    document,
    documentId,
    versionId,
    versionNumber,
    workingRevision,
    updatedAt: optionalString(record, "updated_at", "updatedAt"),
  };
}

function summaryFromWire(value: unknown): DocumentSummary {
  if (!value || typeof value !== "object") throw new DocumentTransportError("Invalid document list response", 502, "invalid_response");
  const record = value as JsonRecord;
  return {
    documentId: requiredString(record, "document_id", "documentId"),
    documentType: requiredString(record, "document_type", "documentType", "type"),
    title: requiredString(record, "title"),
    slug: requiredString(record, "slug"),
    versionId: requiredString(record, "version_id", "versionId"),
    versionNumber: requiredNumber(record, "version_number", "versionNumber"),
    workingRevision: requiredNumber(record, "revision_number", "working_revision", "workingRevision"),
    updatedAt: optionalString(record, "updated_at", "updatedAt"),
  };
}

function documentPayload(document: EditorDocument): JsonRecord {
  return {
    document_id: document.serverDocumentId,
    version_id: document.serverVersionId,
    expected_revision: document.workingRevision,
    document_type: document.documentType,
    title: document.title,
    slug: document.slug,
    description: document.description || null,
    language: "en",
    sections: document.sections.map((section) => ({ ...section, id: Number.isSafeInteger(Number(section.id)) ? Number(section.id) : undefined })),
  };
}

export function createDocumentTransport(fetcher: typeof fetch = fetch, basePath = "/admin/api/documents"): DocumentTransport {
  async function request(path: string, init: RequestInit = {}): Promise<unknown> {
    const headers = new Headers(init.headers);
    headers.set("accept", "application/json");
    if (init.body !== undefined) headers.set("content-type", "application/json");
    const response = await fetcher(`${basePath}${path}`, { ...init, headers, credentials: "same-origin" });
    const raw = await response.text();
    let body: unknown = null;
    if (raw) {
      try {
        body = JSON.parse(raw);
      } catch {
        body = null;
      }
    }
    if (!response.ok) {
      const record = body && typeof body === "object" ? body as JsonRecord : {};
      const code = typeof record.code === "string" ? record.code : undefined;
      const message = typeof record.message === "string" ? record.message : response.statusText || "Document request failed";
      throw new DocumentTransportError(message, response.status, code);
    }
    return body;
  }

  return {
    async listDocuments() {
      const body = await request("");
      const values: unknown[] | null = body && typeof body === "object" && Array.isArray((body as JsonRecord).documents)
        ? (body as JsonRecord).documents as unknown[]
        : Array.isArray(body) ? body : null;
      if (!values) throw new DocumentTransportError("Invalid document list response", 502, "invalid_response");
      return values.map(summaryFromWire);
    },
    async createDraft(input) {
      const body = await request("", { method: "POST", body: JSON.stringify({
        document_type: input.documentType || "article",
        title: input.title,
        slug: input.slug,
        description: input.description || null,
        language: input.language || "en",
        markdown: "",
      }) });
      return draftFromWire(body);
    },
    async loadDraft(documentId) {
      return draftFromWire(await request(`/${encodeURIComponent(documentId)}`));
    },
    async saveDraft(document) {
      const body = await request(`/${encodeURIComponent(document.serverDocumentId || "")}`, {
        method: "PUT",
        body: JSON.stringify(documentPayload(document)),
      });
      if (!body || typeof body !== "object") throw new DocumentTransportError("Invalid save response", 502, "invalid_response");
      const record = body as JsonRecord;
      return {
        documentId: requiredString(record, "document_id", "documentId"),
        versionId: requiredString(record, "version_id", "versionId"),
        versionNumber: requiredNumber(record, "version_number", "versionNumber"),
        workingRevision: requiredNumber(record, "revision_number", "working_revision", "workingRevision"),
      };
    },
  };
}
