import type { EditorDocument } from "./model";

export const recoverySchemaVersion = 1;
const databaseName = "verso-editor-recovery";
const objectStoreName = "snapshots";
const localStoragePrefix = `verso:editor-recovery:${recoverySchemaVersion}:`;
const defaultMaximumBytes = 512 * 1024;
const defaultMaximumEntries = 32;

export type RecoveryScope = {
  siteNamespace: string;
  ownerScope: string;
};

export type LocalDraftPresentation = {
  titleMode: "edit" | "preview";
  detailsOpen: boolean;
  activeSectionId: string | null;
  sectionModes: Array<{ id: string; mode: "edit" | "preview" }>;
};

export type LocalDraftSnapshot = {
  schemaVersion: number;
  siteNamespace: string;
  ownerScope: string;
  draftId: string;
  document: EditorDocument;
  serverDocumentId?: string;
  serverVersionId?: string;
  serverVersionNumber?: number;
  baseServerVersion?: number;
  workingRevision?: number;
  updatedAt: number;
  presentation?: LocalDraftPresentation;
};

export type RecoveryStore = {
  readonly backend: "indexeddb" | "localStorage";
  save(snapshot: LocalDraftSnapshot): Promise<void>;
  get(scope: RecoveryScope, draftId: string): Promise<LocalDraftSnapshot | null>;
  list(scope: RecoveryScope): Promise<LocalDraftSnapshot[]>;
  remove(scope: RecoveryScope, draftId: string): Promise<void>;
};

export class RecoveryStorageError extends Error {
  override name = "RecoveryStorageError";
}

export type RecoveryStoreOptions = {
  indexedDB?: IDBFactory;
  localStorage?: Storage;
  databaseName?: string;
  maximumBytes?: number;
  maximumEntries?: number;
};

function scopeKey(scope: RecoveryScope, draftId: string): string {
  return JSON.stringify([scope.siteNamespace, scope.ownerScope, draftId]);
}

function localKey(scope: RecoveryScope, draftId: string): string {
  return `${localStoragePrefix}${encodeURIComponent(scopeKey(scope, draftId))}`;
}

function snapshotKey(snapshot: LocalDraftSnapshot): string {
  return scopeKey(snapshot, snapshot.draftId);
}

function parseSnapshot(value: unknown): LocalDraftSnapshot | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Partial<LocalDraftSnapshot>;
  if (candidate.schemaVersion !== recoverySchemaVersion) return null;
  if (typeof candidate.siteNamespace !== "string" || typeof candidate.ownerScope !== "string") return null;
  if (typeof candidate.draftId !== "string" || typeof candidate.updatedAt !== "number") return null;
  if (!candidate.document || typeof candidate.document !== "object" || !Array.isArray(candidate.document.sections)) return null;
  if (candidate.document.clientDraftId !== candidate.draftId) return null;
  if (typeof candidate.document.schemaVersion !== "number" || typeof candidate.document.documentType !== "string" || typeof candidate.document.title !== "string" || typeof candidate.document.slug !== "string" || typeof candidate.document.description !== "string") return null;
  if (!candidate.document.sections.every((section) => {
    if (!section || typeof section !== "object" || typeof section.id !== "string") return false;
    if (section.kind === "text") return typeof section.markdown === "string";
    return section.kind === "image" && typeof section.asset === "string" && typeof section.alt === "string" && typeof section.caption === "string" && typeof section.display === "string";
  })) return null;
  if (candidate.serverDocumentId !== undefined && typeof candidate.serverDocumentId !== "string") return null;
  if (candidate.serverVersionId !== undefined && typeof candidate.serverVersionId !== "string") return null;
  if (candidate.serverVersionNumber !== undefined && typeof candidate.serverVersionNumber !== "number") return null;
  if (candidate.baseServerVersion !== undefined && typeof candidate.baseServerVersion !== "number") return null;
  if (candidate.workingRevision !== undefined && typeof candidate.workingRevision !== "number") return null;
  if (candidate.presentation !== undefined) {
    if (typeof candidate.presentation !== "object" || (candidate.presentation.titleMode !== "edit" && candidate.presentation.titleMode !== "preview") || typeof candidate.presentation.detailsOpen !== "boolean" || (candidate.presentation.activeSectionId !== null && typeof candidate.presentation.activeSectionId !== "string") || !Array.isArray(candidate.presentation.sectionModes)) return null;
    if (!candidate.presentation.sectionModes.every((entry) => entry && typeof entry.id === "string" && (entry.mode === "edit" || entry.mode === "preview"))) return null;
  }
  return candidate as LocalDraftSnapshot;
}

function serializedBytes(value: unknown): number {
  return new TextEncoder().encode(JSON.stringify(value)).byteLength;
}

function normalizeSnapshot(snapshot: LocalDraftSnapshot): LocalDraftSnapshot {
  const parsed = parseSnapshot({ ...snapshot, schemaVersion: recoverySchemaVersion });
  if (!parsed) throw new RecoveryStorageError("Invalid local draft snapshot");
  // Svelte 5 state values can be reactive Proxy objects. JSON round-tripping
  // first produces a storage-safe plain snapshot before structuredClone runs.
  const plain = JSON.parse(JSON.stringify(parsed)) as LocalDraftSnapshot;
  if (typeof structuredClone === "function") return structuredClone(plain);
  return plain;
}

function openDatabase(factory: IDBFactory, name: string): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    let request: IDBOpenDBRequest;
    try {
      request = factory.open(name, 1);
    } catch (error) {
      reject(error);
      return;
    }
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(objectStoreName)) request.result.createObjectStore(objectStoreName, { keyPath: "key" });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error("IndexedDB could not be opened"));
  });
}

function indexedDbOperation<T>(database: IDBDatabase, operation: (store: IDBObjectStore, resolve: (value: T) => void, reject: (reason?: unknown) => void) => void): Promise<T> {
  return new Promise((resolve, reject) => {
    let transaction: IDBTransaction;
    try {
      transaction = database.transaction(objectStoreName, "readwrite");
      operation(transaction.objectStore(objectStoreName), resolve, reject);
      transaction.onerror = () => reject(transaction.error || new Error("IndexedDB transaction failed"));
      transaction.onabort = () => reject(transaction.error || new Error("IndexedDB transaction was aborted"));
    } catch (error) {
      reject(error);
    }
  });
}

export function createIndexedDbStore(factory: IDBFactory, options: Pick<RecoveryStoreOptions, "databaseName"> = {}): RecoveryStore {
  const databasePromise = openDatabase(factory, options.databaseName || databaseName);
  return {
    backend: "indexeddb",
    async save(snapshot) {
      const normalized = normalizeSnapshot(snapshot);
      const database = await databasePromise;
      await indexedDbOperation<void>(database, (store, resolve, reject) => {
        const request = store.put({ ...normalized, key: snapshotKey(normalized) });
        request.onsuccess = () => resolve();
        request.onerror = () => reject(request.error || new Error("IndexedDB snapshot save failed"));
      });
    },
    async get(scope, draftId) {
      const database = await databasePromise;
      return indexedDbOperation<LocalDraftSnapshot | null>(database, (store, resolve, reject) => {
        const request = store.get(scopeKey(scope, draftId));
        request.onsuccess = () => resolve(parseSnapshot(request.result));
        request.onerror = () => reject(request.error || new Error("IndexedDB snapshot lookup failed"));
      });
    },
    async list(scope) {
      const database = await databasePromise;
      return indexedDbOperation<LocalDraftSnapshot[]>(database, (store, resolve, reject) => {
        const request = store.getAll();
        request.onsuccess = () => resolve((request.result as unknown[]).map(parseSnapshot).filter((snapshot): snapshot is LocalDraftSnapshot => Boolean(snapshot && snapshot.siteNamespace === scope.siteNamespace && snapshot.ownerScope === scope.ownerScope)).sort((left, right) => right.updatedAt - left.updatedAt));
        request.onerror = () => reject(request.error || new Error("IndexedDB snapshot listing failed"));
      });
    },
    async remove(scope, draftId) {
      const database = await databasePromise;
      await indexedDbOperation<void>(database, (store, resolve, reject) => {
        const request = store.delete(scopeKey(scope, draftId));
        request.onsuccess = () => resolve();
        request.onerror = () => reject(request.error || new Error("IndexedDB snapshot removal failed"));
      });
    },
  };
}

export function createLocalStorageStore(storage: Storage, options: Pick<RecoveryStoreOptions, "maximumBytes" | "maximumEntries"> = {}): RecoveryStore {
  const maximumBytes = options.maximumBytes ?? defaultMaximumBytes;
  const maximumEntries = options.maximumEntries ?? defaultMaximumEntries;
  function readEntries(): LocalDraftSnapshot[] {
    const entries: LocalDraftSnapshot[] = [];
    for (let index = 0; index < storage.length; index += 1) {
      const key = storage.key(index);
      if (!key || !key.startsWith(localStoragePrefix)) continue;
      const raw = storage.getItem(key);
      if (!raw) continue;
      try {
        const snapshot = parseSnapshot(JSON.parse(raw));
        if (snapshot) entries.push(snapshot);
      } catch {
        // Ignore corrupted fallback entries; a later save can replace them.
      }
    }
    return entries;
  }
  return {
    backend: "localStorage",
    async save(snapshot) {
      const normalized = normalizeSnapshot(snapshot);
      const bytes = serializedBytes(normalized);
      if (bytes > maximumBytes) throw new RecoveryStorageError("Local draft is too large for browser fallback storage");
      const key = localKey(normalized, normalized.draftId);
      const existing = readEntries().filter((entry) => localKey(entry, entry.draftId) !== key).sort((left, right) => right.updatedAt - left.updatedAt);
      const retained = [normalized, ...existing].slice(0, maximumEntries);
      try {
        for (const entry of existing) {
          if (!retained.some((candidate) => localKey(candidate, candidate.draftId) === localKey(entry, entry.draftId))) storage.removeItem(localKey(entry, entry.draftId));
        }
        storage.setItem(key, JSON.stringify(normalized));
      } catch (error) {
        throw new RecoveryStorageError(`Local draft fallback storage failed: ${error instanceof Error ? error.message : "unknown error"}`);
      }
    },
    async get(scope, draftId) {
      try {
        const raw = storage.getItem(localKey(scope, draftId));
        return raw ? parseSnapshot(JSON.parse(raw)) : null;
      } catch (error) {
        throw new RecoveryStorageError(`Local draft fallback lookup failed: ${error instanceof Error ? error.message : "unknown error"}`);
      }
    },
    async list(scope) {
      return readEntries().filter((entry) => entry.siteNamespace === scope.siteNamespace && entry.ownerScope === scope.ownerScope).sort((left, right) => right.updatedAt - left.updatedAt);
    },
    async remove(scope, draftId) {
      try {
        storage.removeItem(localKey(scope, draftId));
      } catch (error) {
        throw new RecoveryStorageError(`Local draft fallback removal failed: ${error instanceof Error ? error.message : "unknown error"}`);
      }
    },
  };
}

export function createBrowserRecoveryStore(options: RecoveryStoreOptions = {}): RecoveryStore | null {
  const indexedDBFactory = options.indexedDB ?? (typeof indexedDB !== "undefined" ? indexedDB : undefined);
  let localStorageValue = options.localStorage;
  if (localStorageValue === undefined && typeof localStorage !== "undefined") {
    try {
      localStorageValue = localStorage;
    } catch {
      localStorageValue = undefined;
    }
  }
  const fallback = localStorageValue ? createLocalStorageStore(localStorageValue, options) : null;
  if (!indexedDBFactory && !fallback) return null;
  if (!indexedDBFactory) return fallback;
  const indexed = createIndexedDbStore(indexedDBFactory, options);
  if (!fallback) return indexed;
  let backend: "indexeddb" | "localStorage" = "indexeddb";
  return {
    get backend() {
      return backend;
    },
    async save(snapshot) {
      try {
        await indexed.save(snapshot);
      } catch {
        backend = "localStorage";
        await fallback.save(snapshot);
        return;
      }
      try {
        await fallback.remove({ siteNamespace: snapshot.siteNamespace, ownerScope: snapshot.ownerScope }, snapshot.draftId);
      } catch {
        // IndexedDB already contains the snapshot; a stale fallback entry is harmless.
      }
    },
    async get(scope, draftId) {
      try {
        const indexedSnapshot = await indexed.get(scope, draftId);
        if (indexedSnapshot) return indexedSnapshot;
        try {
          return await fallback.get(scope, draftId);
        } catch {
          return null;
        }
      } catch {
        backend = "localStorage";
        return fallback.get(scope, draftId);
      }
    },
    async list(scope) {
      try {
        const indexedSnapshots = await indexed.list(scope);
        let fallbackSnapshots: LocalDraftSnapshot[] = [];
        try {
          fallbackSnapshots = await fallback.list(scope);
        } catch {
          // IndexedDB remains usable when the browser blocks the fallback store.
        }
        const snapshots = new Map(fallbackSnapshots.map((snapshot) => [snapshot.draftId, snapshot]));
        indexedSnapshots.forEach((snapshot) => snapshots.set(snapshot.draftId, snapshot));
        return [...snapshots.values()].sort((left, right) => right.updatedAt - left.updatedAt);
      } catch {
        backend = "localStorage";
        return fallback.list(scope);
      }
    },
    async remove(scope, draftId) {
      try {
        await indexed.remove(scope, draftId);
        try {
          await fallback.remove(scope, draftId);
        } catch {
          // IndexedDB is clean; a blocked fallback store has nothing to remove.
        }
      } catch {
        backend = "localStorage";
        await fallback.remove(scope, draftId);
      }
    },
  };
}

export function makeSnapshot(scope: RecoveryScope, document: EditorDocument, updatedAt = Date.now(), presentation?: LocalDraftPresentation): LocalDraftSnapshot {
  return normalizeSnapshot({
    schemaVersion: recoverySchemaVersion,
    siteNamespace: scope.siteNamespace,
    ownerScope: scope.ownerScope,
    draftId: document.clientDraftId,
    document,
    serverDocumentId: document.serverDocumentId,
    serverVersionId: document.serverVersionId,
    serverVersionNumber: document.serverVersionNumber,
    baseServerVersion: document.baseServerVersion,
    workingRevision: document.workingRevision,
    updatedAt,
    presentation,
  });
}

export function snapshotDiffers(left: EditorDocument, right: EditorDocument): boolean {
  return JSON.stringify(left) !== JSON.stringify(right);
}
