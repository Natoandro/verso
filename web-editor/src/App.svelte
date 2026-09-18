<svelte:options runes={true} />

<script lang="ts">
  import { tick, untrack } from "svelte";
  import IconButton from "./IconButton.svelte";
  import SectionCard from "./SectionCard.svelte";
  import type { EditorDocument } from "./model";
  import { createPreviewRenderer, renderSection, type PreviewRenderer } from "./renderer";
  import { ensureDraftScopedUrl, readDraftId } from "./draft-route";
  import { createBrowserRecoveryStore, makeSnapshot, type LocalDraftPresentation, type RecoveryScope } from "./recovery";
  import { classifyRecovery, mergeDocuments, type RecoveryCandidate } from "./recovery-policy";
  import { createEditorState, reduceEditorState, type EditorAction, type EditorState } from "./state";
  import { createDocumentTransport, DocumentTransportError, type ServerDraft } from "./transport";

  let sequence = 0;
  const idFactory = () => {
    if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") return `local-${crypto.randomUUID()}`;
    return `local-${Date.now().toString(36)}-${(++sequence).toString(36)}-${Math.random().toString(36).slice(2)}`;
  };
  const editorMount = document.querySelector<HTMLElement>("[data-editor-mount]");
  const transport = createDocumentTransport();
  const documentId = new URL(window.location.href).searchParams.get("document");
  const scope: RecoveryScope = {
    siteNamespace: editorMount?.dataset.siteNamespace || window.location.origin,
    ownerScope: editorMount?.dataset.ownerScope || "anonymous",
  };

  function newDraftId(): string {
    if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") return `draft-${crypto.randomUUID()}`;
    return `draft-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  }

  type RecoveryUiState = {
    phase: "loading" | "ready" | "unavailable";
    message: string;
    candidates: RecoveryCandidate[];
  };

  const initialDraftId = readDraftId() || (documentId ? `server-${documentId}` : newDraftId());
  if (!documentId && !readDraftId()) ensureDraftScopedUrl(initialDraftId);
  const recoveryStore = createBrowserRecoveryStore();
  // The reducer returns a new root state for every action. Keep it raw so
  // Svelte does not proxy Maps/sections or leak reactive proxies into storage.
  let editorState: EditorState = $state.raw(createEditorState({ clientDraftId: initialDraftId, sections: [] }, idFactory));
  // Recovery UI is also replaced immutably. Keeping it raw avoids a second
  // proxy graph being reconciled while the keyed section list changes.
  let recoveryUi: RecoveryUiState = $state.raw({ phase: "loading", message: "Checking browser recovery…", candidates: [] });
  let persistence = $state.raw({ phase: documentId ? "loading" : "local", message: documentId ? "Loading saved draft…" : "Browser-local draft" });
  let persistedDraft: ServerDraft | undefined;
  let editorTouched = false;
  let autosaveTimer: ReturnType<typeof setTimeout> | undefined;
  let lastSnapshotTime = 0;
  let saveQueue: Promise<void> = Promise.resolve();
  const previewSchedulers = new Map<string, PreviewRenderer<EditorDocument["sections"][number]>>();

  let sectionCount = $derived(editorState.document.sections.length);
  let saveLabel = $derived(persistence.phase === "saving" ? "Saving…" : persistence.phase === "conflict" ? "Resolve conflict" : "Save draft");
  let statusText = $derived(editorState.status === "validating"
    ? "Validating local section preview…"
    : editorState.status === "editing"
      ? `${editorState.document.serverDocumentId ? "Unsaved server draft changes" : "Unsaved browser-local document"} · ${recoveryUi.message || "changes are held in memory"}`
      : recoveryUi.phase === "loading"
        ? "Checking browser recovery…"
        : `${editorState.document.serverDocumentId ? "Saved draft" : "Unsaved browser-local document"} · ${sectionCount} section${sectionCount === 1 ? "" : "s"}${recoveryUi.message ? ` · ${recoveryUi.message}` : ""}`);

  function syncPublicState(): void {
    window.__versoEditorState = editorState.document;
  }

  function dispatch(action: EditorAction): void {
    editorTouched = true;
    editorState = reduceEditorState(editorState, action, idFactory);
    syncPublicState();
    if ((action.type === "set-title-mode" && action.mode === "preview") || action.type === "set-section-preview") {
      setTimeout(() => void saveLocalSnapshot(), 0);
    }
  }

  function updateRecoveryUi(changes: Partial<RecoveryUiState>): void {
    recoveryUi = { ...recoveryUi, ...changes };
  }

  function presentationSnapshot(currentState: EditorState): LocalDraftPresentation {
    return {
      titleMode: currentState.titleMode,
      detailsOpen: currentState.detailsOpen,
      activeSectionId: currentState.activeSectionId,
      sectionModes: [...currentState.sectionModes.entries()].map(([id, mode]) => ({ id, mode })),
    };
  }

  function applySnapshot(document: EditorDocument, presentation?: LocalDraftPresentation): void {
    const restored = createEditorState(document, idFactory);
    if (presentation) {
      restored.titleMode = presentation.titleMode;
      restored.detailsOpen = presentation.detailsOpen;
      restored.activeSectionId = restored.document.sections.some((section) => section.id === presentation.activeSectionId) ? presentation.activeSectionId : null;
      for (const entry of presentation.sectionModes) {
        const section = restored.document.sections.find((candidate) => candidate.id === entry.id);
        if (!section) continue;
        restored.sectionModes.set(entry.id, entry.mode);
        if (entry.mode === "preview") restored.sectionPreviewHtml.set(entry.id, renderSection(section));
      }
    }
    editorState = restored;
    syncPublicState();
  }

  async function saveLocalSnapshot(document: EditorDocument = editorState.document, presentation: LocalDraftPresentation = presentationSnapshot(editorState)): Promise<void> {
    if (!recoveryStore || recoveryUi.phase === "loading") return;
    lastSnapshotTime = Math.max(Date.now(), lastSnapshotTime + 1);
    try {
      const snapshot = makeSnapshot(scope, document, lastSnapshotTime, presentation);
      const save = saveQueue.catch(() => undefined).then(() => recoveryStore.save(snapshot));
      saveQueue = save.then(() => undefined, () => undefined);
      await save;
      updateRecoveryUi({ message: recoveryStore.backend === "indexeddb" ? "recovery saved" : "recovery saved in limited browser storage" });
    } catch (error) {
      updateRecoveryUi({ message: `recovery unavailable: ${error instanceof Error ? error.message : "storage failed"}` });
    }
  }

  async function initializeRecovery(): Promise<void> {
    if (!recoveryStore) {
      updateRecoveryUi({ phase: "unavailable", message: "browser storage unavailable; editing continues" });
      return;
    }
    try {
      const snapshots = await recoveryStore.list(scope);
      const matching = snapshots.find((snapshot) => snapshot.draftId === initialDraftId);
      const matchingConflicts = matching && persistedDraft
        ? classifyRecovery([matching], initialDraftId, {
          document: persistedDraft.document,
          serverDocumentId: persistedDraft.documentId,
          serverVersionId: persistedDraft.versionId,
          workingRevision: persistedDraft.workingRevision,
        }).length > 0
        : false;
      if (matching && !editorTouched && !matchingConflicts) {
        lastSnapshotTime = matching.updatedAt;
        applySnapshot(matching.document, matching.presentation);
        updateRecoveryUi({ message: "matching local draft resumed" });
      } else if (matching) {
        updateRecoveryUi({ message: matchingConflicts ? "saved draft differs from browser recovery" : "recovery ready; current edits preserved" });
      } else {
        updateRecoveryUi({ message: "recovery ready" });
      }
      updateRecoveryUi({
        candidates: classifyRecovery(snapshots, initialDraftId, persistedDraft ? {
          document: persistedDraft.document,
          serverDocumentId: persistedDraft.documentId,
          serverVersionId: persistedDraft.versionId,
          workingRevision: persistedDraft.workingRevision,
        } : undefined),
        phase: "ready",
      });
    } catch (error) {
      updateRecoveryUi({ phase: "unavailable", message: `recovery unavailable: ${error instanceof Error ? error.message : "storage failed"}; editing continues` });
    }
  }

  function documentForServer(draft: ServerDraft): EditorDocument {
    return { ...draft.document, clientDraftId: initialDraftId };
  }

  async function initializeEditor(): Promise<void> {
    if (documentId) {
      try {
        const draft = await transport.loadDraft(documentId);
        persistedDraft = draft;
        editorState = reduceEditorState(editorState, { type: "hydrate-document", document: documentForServer(draft) }, idFactory);
        editorTouched = false;
        persistence = { phase: "ready", message: `Saved draft · revision ${draft.workingRevision}` };
      } catch (error) {
        persistence = { phase: "error", message: error instanceof Error ? error.message : "Saved draft could not be loaded" };
      }
    }
    await initializeRecovery();
  }

  async function saveDraft(): Promise<void> {
    if (!editorState.document.serverDocumentId) {
      persistence = { phase: "local", message: "Create a saved draft from the document index first" };
      return;
    }
    persistence = { phase: "saving", message: "Saving draft…" };
    try {
      const result = await transport.saveDraft(editorState.document);
      editorState = reduceEditorState(editorState, {
        type: "set-server-state",
        serverDocumentId: result.documentId,
        serverVersionId: result.versionId,
        serverVersionNumber: result.versionNumber,
        workingRevision: result.workingRevision,
      }, idFactory);
      persistedDraft = {
        document: editorState.document,
        documentId: result.documentId,
        versionId: result.versionId,
        versionNumber: result.versionNumber,
        workingRevision: result.workingRevision,
      };
      editorTouched = false;
      try {
        await recoveryStore?.remove(scope, editorState.document.clientDraftId);
      } catch {
        // A successful server save remains canonical even if local cleanup fails.
      }
      persistence = { phase: "ready", message: `Saved · revision ${result.workingRevision}` };
    } catch (error) {
      const transportError = error instanceof DocumentTransportError ? error : undefined;
      persistence = {
        phase: transportError?.stale ? "conflict" : "error",
        message: transportError?.stale
          ? "This draft changed elsewhere. Load the newer draft or reconcile local recovery before saving again."
          : error instanceof Error ? error.message : "Draft could not be saved",
      };
    }
  }

  async function resolveRecovery(candidate: RecoveryCandidate, decision: "restore" | "merge" | "discard"): Promise<void> {
    if (decision === "restore") {
      ensureDraftScopedUrl(candidate.snapshot.draftId);
      applySnapshot(candidate.snapshot.document, candidate.snapshot.presentation);
      lastSnapshotTime = candidate.snapshot.updatedAt;
    } else if (decision === "merge") {
      applySnapshot(mergeDocuments(candidate.snapshot.document, editorState.document));
    }
    try {
      await recoveryStore?.remove(scope, candidate.snapshot.draftId);
      updateRecoveryUi({
        candidates: recoveryUi.candidates.filter((item) => item.snapshot.draftId !== candidate.snapshot.draftId),
        message: decision === "discard" ? "local recovery discarded" : "local recovery selected",
      });
    } catch (error) {
      updateRecoveryUi({ message: `recovery cleanup failed: ${error instanceof Error ? error.message : "storage failed"}` });
    }
  }

  function schedulerFor(id: string): PreviewRenderer<EditorDocument["sections"][number]> {
    let scheduler = previewSchedulers.get(id);
    if (!scheduler) {
      scheduler = createPreviewRenderer();
      previewSchedulers.set(id, scheduler);
    }
    return scheduler;
  }

  function invalidateSection(id: string): void {
    schedulerFor(id).cancel();
    dispatch({ type: "invalidate-section", id });
  }

  function validateSection(id: string): void {
    const section = editorState.document.sections.find((candidate) => candidate.id === id);
    if (!section) return;
    dispatch({ type: "set-status", status: "validating" });
    schedulerFor(id).request(section, (html) => dispatch({ type: "set-section-preview", id, html })).catch(() => {
      dispatch({ type: "set-section-error", id, message: "This section could not be rendered safely. It remains in edit mode." });
    });
  }

  function handleSectionAction(id: string, action: "move-up" | "move-down" | "duplicate" | "delete" | "validate-section" | "edit-section"): void {
    dispatch({ type: "set-active-section", id });
    if (action === "validate-section") return validateSection(id);
    if (action === "edit-section") {
      invalidateSection(id);
      return;
    }
    if (action === "delete") {
      invalidateSection(id);
      previewSchedulers.delete(id);
      dispatch({ type: "delete-section", id });
      return;
    }
    if (action === "duplicate") return dispatch({ type: "duplicate-section", id });
    dispatch({ type: "move-section", id, offset: action === "move-up" ? -1 : 1 });
  }

  function addSection(kind: "text" | "image"): void {
    dispatch({ type: "add-section", kind });
  }

  function inputValue(event: Event): string {
    return (event.currentTarget as HTMLInputElement | HTMLTextAreaElement).value;
  }

  function resizeTitleInput(inputElement: HTMLTextAreaElement): void {
    inputElement.style.height = "auto";
    inputElement.style.height = `${inputElement.scrollHeight}px`;
  }

  function titleInput(event: Event): void {
    const inputElement = event.currentTarget as HTMLTextAreaElement;
    resizeTitleInput(inputElement);
    const title = inputElement.value.replace(/\r\n?/g, "\n").replace(/[ \t]+/g, " ").trim();
    dispatch({ type: "update-metadata", changes: { title } });
  }

  function titleKeydown(event: KeyboardEvent): void {
    if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
      event.preventDefault();
      dispatch({ type: "set-title-mode", mode: "preview" });
    }
  }

  function attachTitleInput(inputElement: HTMLTextAreaElement): void {
    // Initialize once per edit-mode mount. Keeping the input uncontrolled while
    // typing prevents state updates from moving the browser-managed caret.
    inputElement.value = untrack(() => editorState.document.title);
    resizeTitleInput(inputElement);
  }

  function setMetadata(field: "slug" | "description", event: Event): void {
    dispatch({ type: "update-metadata", changes: { [field]: inputValue(event) } });
  }

  function insertText(): void {
    addSection("text");
  }

  function insertImagePlaceholder(): void {
    addSection("image");
  }

  async function editTitle(): Promise<void> {
    dispatch({ type: "set-title-mode", mode: "edit" });
    await tick();
    document.getElementById("document-title")?.focus();
  }

  $effect(() => {
    editorState.document;
    editorState.titleMode;
    editorState.detailsOpen;
    editorState.activeSectionId;
    editorState.sectionModes;
    if (recoveryUi.phase === "loading") return;
    if (autosaveTimer) clearTimeout(autosaveTimer);
    autosaveTimer = setTimeout(() => void saveLocalSnapshot(), 650);
    return () => {
      if (autosaveTimer) clearTimeout(autosaveTimer);
    };
  });

  $effect(() => {
    const saveOnLeave = () => void saveLocalSnapshot();
    window.addEventListener("pagehide", saveOnLeave);
    return () => window.removeEventListener("pagehide", saveOnLeave);
  });

  $effect(() => {
    syncPublicState();
    window.VersoEditor = { getDocument: () => editorState.document, insertText, insertImagePlaceholder };
  });

  void initializeEditor();
</script>

<main class="editor-shell" data-editor data-local-only data-model-schema-version="1" data-draft-id={editorState.document.clientDraftId}>
  <header class="editor-header">
    <div class="editor-context">
      <p class="eyebrow">Verso</p>
      <p class="editor-heading">Compose document</p>
    </div>
    <div class="editor-header-actions">
      <IconButton icon="details" label="Document details" pressed={editorState.detailsOpen} onclick={() => dispatch({ type: "toggle-details" })} />
      {#if editorState.document.serverDocumentId}
        <button type="button" class="save-button" disabled={persistence.phase === "saving"} onclick={() => void saveDraft()}>{saveLabel}</button>
      {/if}
      <span class="local-badge">Browser-local</span>
    </div>
  </header>

  {#if recoveryUi.candidates.length > 0}
    <section class="recovery-panel" aria-live="polite" aria-label="Browser draft recovery">
      <div>
        <strong>Other local drafts are available.</strong>
        <p>Choose explicitly before bringing another browser snapshot into this editor.</p>
      </div>
      {#each recoveryUi.candidates as candidate (candidate.snapshot.draftId)}
        <div class="recovery-candidate">
          <span>{candidate.reason === "server-conflict" ? "Conflict with saved draft" : candidate.snapshot.document.title || "Untitled document"} · {new Date(candidate.snapshot.updatedAt).toLocaleString()}</span>
          <span class="recovery-actions">
            <button type="button" onclick={() => void resolveRecovery(candidate, "restore")}>Restore</button>
            <button type="button" onclick={() => void resolveRecovery(candidate, "merge")}>Merge</button>
            <button type="button" onclick={() => void resolveRecovery(candidate, "discard")}>Discard</button>
          </span>
        </div>
      {/each}
    </section>
  {/if}

  <section class="document-article" aria-labelledby="document-title">
    <div class="article-title-row">
      <div class="article-title-content">
        {#if editorState.titleMode === "edit"}
          <textarea {@attach attachTitleInput} id="document-title" class="document-title document-title-editor" data-placeholder="Untitled document" placeholder="Untitled document" rows="1" aria-label="Edit document title" oninput={titleInput} onkeydown={titleKeydown}></textarea>
        {:else}
          <h1 id="document-title" class="document-title" data-placeholder="Untitled document" aria-label="Document title">{editorState.document.title}</h1>
        {/if}
        {#if editorState.document.description}<p class="article-description">{editorState.document.description}</p>{/if}
      </div>
      <div class="title-actions">
        <IconButton icon={editorState.titleMode === "edit" ? "check" : "edit"} label={editorState.titleMode === "edit" ? "Validate title" : "Edit title"} onclick={() => {
          if (editorState.titleMode === "edit") dispatch({ type: "set-title-mode", mode: "preview" });
          else void editTitle();
        }} />
      </div>
    </div>

    <div class="details-panel" hidden={!editorState.detailsOpen}>
      {#if editorState.detailsOpen}
        <div class="details-grid">
          <input value={editorState.document.slug} aria-label="URL slug" placeholder="URL slug" oninput={(event) => setMetadata("slug", event)} />
          <textarea rows="2" value={editorState.document.description} aria-label="Short description" placeholder="Short description" oninput={(event) => setMetadata("description", event)}></textarea>
        </div>
      {/if}
    </div>

    <div class="article-toolbar"><span class="section-count">{sectionCount} section{sectionCount === 1 ? "" : "s"}</span></div>
    <div class="section-list" aria-live="polite">
      {#if sectionCount === 0}<p class="empty-state">Your article is empty. Add text or an image placeholder to begin.</p>{/if}
      {#each editorState.document.sections as section, index (section.id)}
        <SectionCard
          {section}
          {index}
          total={sectionCount}
          active={section.id === editorState.activeSectionId}
          mode={editorState.sectionModes.get(section.id) || "edit"}
          previewHtml={editorState.sectionPreviewHtml.get(section.id)}
          error={editorState.sectionErrors.get(section.id)}
          onActivate={() => dispatch({ type: "set-active-section", id: section.id })}
          onAction={(action) => handleSectionAction(section.id, action)}
          onFieldChange={(field, value) => {
            invalidateSection(section.id);
            dispatch({ type: "update-section", id: section.id, changes: { [field]: value } });
          }}
        />
      {/each}
    </div>
    <div class="add-section">
      <span class="add-section-label">Add to article</span>
      <IconButton icon="text" label="Add text" onclick={() => addSection("text")} />
      <IconButton icon="image" label="Add image placeholder" onclick={() => addSection("image")} />
    </div>
  </section>

  <footer class="editor-footer">
    <span class="status-dot" aria-hidden="true"></span>
    <span>{statusText}</span>
    <span class="footer-note">{persistence.message}. Saving and publishing are separate operations.</span>
  </footer>
</main>
