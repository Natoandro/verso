import {
  createDocument,
  deleteSection,
  duplicateSection,
  insertSection,
  moveSection,
  updateMetadata,
  updateSection,
  type EditorDocument,
  type IdFactory,
  type Section,
} from "./model";

export type TitleMode = "edit" | "preview";
export type SectionMode = "edit" | "preview";
export type EditorStatus = "idle" | "editing" | "validating";

export type EditorState = {
  document: EditorDocument;
  titleMode: TitleMode;
  detailsOpen: boolean;
  activeSectionId: string | null;
  sectionModes: Map<string, SectionMode>;
  sectionPreviewHtml: Map<string, string>;
  sectionErrors: Map<string, string>;
  status: EditorStatus;
};

export type EditorAction =
  | { type: "hydrate-document"; document: EditorDocument }
  | { type: "set-server-state"; serverDocumentId: string; serverVersionId: string; serverVersionNumber: number; workingRevision: number }
  | { type: "toggle-details" }
  | { type: "set-active-section"; id: string | null }
  | { type: "set-title-mode"; mode: TitleMode }
  | { type: "update-metadata"; changes: Partial<Pick<EditorDocument, "title" | "slug" | "description">> }
  | { type: "update-section"; id: string; changes: Partial<Section> }
  | { type: "invalidate-section"; id: string }
  | { type: "set-section-preview"; id: string; html: string }
  | { type: "set-section-error"; id: string; message: string }
  | { type: "set-status"; status: EditorStatus }
  | { type: "add-section"; kind: "text" | "image" }
  | { type: "delete-section"; id: string }
  | { type: "duplicate-section"; id: string }
  | { type: "move-section"; id: string; offset: -1 | 1 };

function copyMap<T>(map: Map<string, T>): Map<string, T> {
  return new Map(map);
}

export function createEditorState(options: Parameters<typeof createDocument>[0] = {}, idFactory?: IdFactory): EditorState {
  return {
    document: createDocument(options, idFactory),
    titleMode: "edit",
    detailsOpen: false,
    activeSectionId: null,
    sectionModes: new Map(),
    sectionPreviewHtml: new Map(),
    sectionErrors: new Map(),
    status: "idle",
  };
}

function markEditing(state: EditorState, document: EditorDocument): EditorState {
  return { ...state, document, status: "editing" };
}

function invalidate(state: EditorState, id: string): EditorState {
  const sectionModes = copyMap(state.sectionModes);
  const sectionPreviewHtml = copyMap(state.sectionPreviewHtml);
  const sectionErrors = copyMap(state.sectionErrors);
  sectionModes.set(id, "edit");
  sectionPreviewHtml.delete(id);
  sectionErrors.delete(id);
  return { ...state, sectionModes, sectionPreviewHtml, sectionErrors };
}

export function reduceEditorState(state: EditorState, action: EditorAction, idFactory: IdFactory): EditorState {
  switch (action.type) {
    case "hydrate-document":
      return createEditorState(action.document, idFactory);
    case "set-server-state":
      return {
        ...state,
        document: {
          ...state.document,
          serverDocumentId: action.serverDocumentId,
          serverVersionId: action.serverVersionId,
          serverVersionNumber: action.serverVersionNumber,
          baseServerVersion: action.serverVersionNumber,
          workingRevision: action.workingRevision,
        },
        status: "idle",
      };
    case "toggle-details":
      return { ...state, detailsOpen: !state.detailsOpen };
    case "set-active-section":
      return { ...state, activeSectionId: action.id };
    case "set-title-mode":
      return { ...state, titleMode: action.mode };
    case "update-metadata":
      return markEditing(state, updateMetadata(state.document, action.changes));
    case "update-section":
      return markEditing(invalidate(state, action.id), updateSection(state.document, action.id, action.changes, idFactory));
    case "invalidate-section":
      return { ...invalidate(state, action.id), status: "editing" };
    case "set-section-preview": {
      const sectionModes = copyMap(state.sectionModes);
      const sectionPreviewHtml = copyMap(state.sectionPreviewHtml);
      const sectionErrors = copyMap(state.sectionErrors);
      sectionModes.set(action.id, "preview");
      sectionPreviewHtml.set(action.id, action.html);
      sectionErrors.delete(action.id);
      return { ...state, sectionModes, sectionPreviewHtml, sectionErrors, status: "idle" };
    }
    case "set-section-error": {
      const sectionModes = copyMap(state.sectionModes);
      const sectionErrors = copyMap(state.sectionErrors);
      sectionModes.set(action.id, "edit");
      sectionErrors.set(action.id, action.message);
      return { ...state, sectionModes, sectionErrors, status: "idle" };
    }
    case "set-status":
      return { ...state, status: action.status };
    case "add-section": {
      const section = action.kind === "image" ? { kind: "image" as const, asset: "", alt: "", caption: "", display: "inline" } : { kind: "text" as const, markdown: "" };
      const document = insertSection(state.document, state.document.sections.length, section, idFactory);
      return { ...markEditing(state, document), activeSectionId: document.sections[document.sections.length - 1].id };
    }
    case "delete-section": {
      const next = invalidate(state, action.id);
      return { ...markEditing(next, deleteSection(state.document, action.id)), activeSectionId: null };
    }
    case "duplicate-section": {
      const index = state.document.sections.findIndex((section) => section.id === action.id);
      const document = duplicateSection(state.document, action.id, index + 1, idFactory);
      return { ...markEditing(state, document), activeSectionId: document.sections[index + 1].id };
    }
    case "move-section": {
      const index = state.document.sections.findIndex((section) => section.id === action.id);
      const document = moveSection(state.document, action.id, index + action.offset);
      return markEditing(state, document);
    }
  }
}
