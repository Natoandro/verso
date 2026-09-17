import type { EditorDocument } from "./model";

declare global {
  interface Window {
    __versoEditorState?: EditorDocument;
    VersoEditor?: {
      getDocument: () => EditorDocument;
      insertText: () => void;
      insertImagePlaceholder: () => void;
    };
  }
}

export {};
