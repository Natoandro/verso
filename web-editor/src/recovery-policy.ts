import type { EditorDocument } from "./model";
import { snapshotDiffers, type LocalDraftSnapshot } from "./recovery";

export type RecoveryDecision = "restore" | "merge" | "discard";
export type PersistedDraft = {
  document: EditorDocument;
  updatedAt?: number;
  serverDocumentId?: string;
  workingRevision?: number;
};

export type RecoveryCandidate = {
  snapshot: LocalDraftSnapshot;
  reason: "non-current" | "server-conflict";
  requiresConsent: true;
};

export function findMatchingSnapshot(snapshots: LocalDraftSnapshot[], draftId: string): LocalDraftSnapshot | null {
  return snapshots.find((snapshot) => snapshot.draftId === draftId) || null;
}

export function nonCurrentSnapshots(snapshots: LocalDraftSnapshot[], draftId: string): LocalDraftSnapshot[] {
  return snapshots.filter((snapshot) => snapshot.draftId !== draftId);
}

export function conflictsWithServer(snapshot: LocalDraftSnapshot, persisted: PersistedDraft): boolean {
  if (snapshot.serverDocumentId && persisted.serverDocumentId && snapshot.serverDocumentId !== persisted.serverDocumentId) return true;
  if (typeof snapshot.workingRevision === "number" && typeof persisted.workingRevision === "number" && snapshot.workingRevision !== persisted.workingRevision) return true;
  if (typeof persisted.updatedAt === "number" && snapshot.updatedAt <= persisted.updatedAt && !snapshotDiffers(snapshot.document, persisted.document)) return false;
  return snapshotDiffers(snapshot.document, persisted.document);
}

export function classifyRecovery(snapshots: LocalDraftSnapshot[], currentDraftId: string, persisted?: PersistedDraft): RecoveryCandidate[] {
  const candidates: RecoveryCandidate[] = [];
  snapshots.forEach((snapshot) => {
    if (persisted && conflictsWithServer(snapshot, persisted)) {
      candidates.push({ snapshot, reason: "server-conflict", requiresConsent: true });
    } else if (snapshot.draftId !== currentDraftId) {
      candidates.push({ snapshot, reason: "non-current", requiresConsent: true });
    }
  });
  return candidates;
}

export function mergeDocuments(local: EditorDocument, persisted: EditorDocument): EditorDocument {
  const existingIds = new Set(persisted.sections.map((section) => section.id));
  const additionalSections = local.sections.filter((section) => !existingIds.has(section.id)).map((section) => ({ ...section }));
  return {
    ...persisted,
    title: local.title || persisted.title,
    slug: local.slug || persisted.slug,
    description: local.description || persisted.description,
    sections: [...persisted.sections.map((section) => ({ ...section })), ...additionalSections],
    clientDraftId: persisted.clientDraftId,
  };
}
