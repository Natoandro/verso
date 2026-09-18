export const schemaVersion = 1;

export type TextSection = {
  id: string;
  kind: "text";
  markdown: string;
};

export type ImageSection = {
  id: string;
  kind: "image";
  asset: string;
  alt: string;
  caption: string;
  display: string;
};

export type Section = TextSection | ImageSection;
export type SectionInput = Partial<TextSection> & { kind: "text" } | Partial<ImageSection> & { kind: "image" };

export type EditorDocument = {
  schemaVersion: number;
  clientDraftId: string;
  serverDocumentId?: string;
  serverVersionId?: string;
  serverVersionNumber?: number;
  baseServerVersion?: number;
  workingRevision?: number;
  documentType: string;
  title: string;
  slug: string;
  description: string;
  sections: Section[];
};

export type DocumentOptions = Partial<Omit<EditorDocument, "sections">> & {
  sections?: SectionInput[];
};

export type IdFactory = () => string;

function defaultId(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") return crypto.randomUUID();
  return `client-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

function copySection(section: Section): Section {
  return { ...section };
}

function copyDocument(document: EditorDocument): EditorDocument {
  return { ...document, sections: document.sections.map(copySection) };
}

function requireDocument(document: EditorDocument): void {
  if (!document || !Array.isArray(document.sections)) throw new TypeError("Invalid editor document");
}

function requireIndex(document: EditorDocument, index: number, allowEnd: boolean): void {
  const maximum = allowEnd ? document.sections.length : document.sections.length - 1;
  if (!Number.isInteger(index) || index < 0 || index > maximum) throw new RangeError("Invalid section position");
}

function sectionIndex(document: EditorDocument, id: string): number {
  const index = document.sections.findIndex((section) => section.id === id);
  if (index < 0) throw new Error("Section not found");
  return index;
}

function normalizeSection(section: SectionInput, idFactory: IdFactory, usedIds?: Set<string>): Section {
  if (!section || (section.kind !== "text" && section.kind !== "image")) throw new TypeError("Invalid section kind");
  let id = section.id || idFactory();
  while (usedIds?.has(id)) id = idFactory();
  usedIds?.add(id);
  if (section.kind === "text") return { id, kind: "text", markdown: typeof section.markdown === "string" ? section.markdown : "" };
  return {
    id,
    kind: "image",
    asset: typeof section.asset === "string" ? section.asset : "",
    alt: typeof section.alt === "string" ? section.alt : "",
    caption: typeof section.caption === "string" ? section.caption : "",
    display: section.display || "inline",
  };
}

export function createDocument(options: DocumentOptions = {}, idFactory: IdFactory = defaultId): EditorDocument {
  const usedSectionIds = new Set<string>();
  return {
    schemaVersion,
    clientDraftId: options.clientDraftId || idFactory(),
    ...(options.serverDocumentId ? { serverDocumentId: options.serverDocumentId } : {}),
    ...(options.serverVersionId ? { serverVersionId: options.serverVersionId } : {}),
    ...(typeof options.serverVersionNumber === "number" ? { serverVersionNumber: options.serverVersionNumber } : {}),
    ...(typeof options.baseServerVersion === "number" ? { baseServerVersion: options.baseServerVersion } : {}),
    ...(typeof options.workingRevision === "number" ? { workingRevision: options.workingRevision } : {}),
    documentType: options.documentType || "article",
    title: options.title || "",
    slug: options.slug || "",
    description: options.description || "",
    sections: (options.sections || []).map((section) => normalizeSection(section, idFactory, usedSectionIds)),
  };
}

export function insertSection(document: EditorDocument, index: number, section: SectionInput, idFactory: IdFactory = defaultId): EditorDocument {
  requireDocument(document);
  requireIndex(document, index, true);
  const result = copyDocument(document);
  const usedSectionIds = new Set(result.sections.map((candidate) => candidate.id));
  result.sections.splice(index, 0, normalizeSection(section, idFactory, usedSectionIds));
  return result;
}

export function updateSection(document: EditorDocument, id: string, changes: Partial<Section>, idFactory: IdFactory = defaultId): EditorDocument {
  requireDocument(document);
  const index = sectionIndex(document, id);
  const result = copyDocument(document);
  result.sections[index] = normalizeSection({ ...result.sections[index], ...changes, id } as SectionInput, idFactory);
  return result;
}

export function moveSection(document: EditorDocument, id: string, position: number): EditorDocument {
  requireDocument(document);
  requireIndex(document, position, false);
  const current = sectionIndex(document, id);
  const result = copyDocument(document);
  const section = result.sections.splice(current, 1)[0];
  result.sections.splice(position, 0, section);
  return result;
}

export function duplicateSection(document: EditorDocument, id: string, position: number, idFactory: IdFactory = defaultId): EditorDocument {
  requireDocument(document);
  requireIndex(document, position, true);
  const source = document.sections[sectionIndex(document, id)];
  return insertSection(document, position, { ...source, id: undefined } as SectionInput, idFactory);
}

export function deleteSection(document: EditorDocument, id: string): EditorDocument {
  requireDocument(document);
  const result = copyDocument(document);
  result.sections.splice(sectionIndex(document, id), 1);
  return result;
}

export function updateMetadata(document: EditorDocument, changes: Partial<Pick<EditorDocument, "title" | "slug" | "description">>): EditorDocument {
  requireDocument(document);
  return { ...copyDocument(document), ...changes };
}
