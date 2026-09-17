<script lang="ts">
  import { tick } from "svelte";
  import IconButton from "./IconButton.svelte";
  import SectionCard from "./SectionCard.svelte";
  import type { EditorDocument } from "./model";
  import { createPreviewRenderer, type PreviewRenderer } from "./renderer";
  import { createEditorState, reduceEditorState, type EditorAction, type EditorState } from "./state";

  let sequence = 0;
  const idFactory = () => `local-${(++sequence).toString(36)}`;
  let state = $state<EditorState>(createEditorState({ sections: [] }, idFactory));
  const previewSchedulers = new Map<string, PreviewRenderer<EditorDocument["sections"][number]>>();

  let sectionCount = $derived(state.document.sections.length);
  let statusText = $derived(state.status === "validating"
    ? "Validating local section preview…"
    : state.status === "editing"
      ? "Unsaved browser-local document · changes are held in memory"
      : `Unsaved browser-local document · ${sectionCount} section${sectionCount === 1 ? "" : "s"}`);

  function syncPublicState(): void {
    window.__versoEditorState = state.document;
  }

  function dispatch(action: EditorAction): void {
    state = reduceEditorState(state, action, idFactory);
    syncPublicState();
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
    const section = state.document.sections.find((candidate) => candidate.id === id);
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

  function titleInput(event: Event): void {
    const title = (event.currentTarget as HTMLElement).textContent?.replace(/\s+/g, " ").trim() || "";
    dispatch({ type: "update-metadata", changes: { title } });
  }

  function titleKeydown(event: KeyboardEvent): void {
    if (event.key === "Enter") {
      event.preventDefault();
      dispatch({ type: "set-title-mode", mode: "preview" });
    }
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
    syncPublicState();
    window.VersoEditor = { getDocument: () => state.document, insertText, insertImagePlaceholder };
  });
</script>

<main class="editor-shell" data-editor data-local-only data-model-schema-version="1">
  <header class="editor-header">
    <div class="editor-context">
      <p class="eyebrow">Verso</p>
      <p class="editor-heading">Compose document</p>
    </div>
    <div class="editor-header-actions">
      <IconButton icon="details" label="Document details" pressed={state.detailsOpen} onclick={() => dispatch({ type: "toggle-details" })} />
      <span class="local-badge">Browser-local</span>
    </div>
  </header>

  <section class="document-article" aria-labelledby="document-title">
    <div class="article-title-row">
      <div class="article-title-content">
        <!-- svelte-ignore a11y_no_noninteractive_element_to_interactive_role -->
        <h1 id="document-title" class="document-title" data-placeholder="Untitled document" role="textbox" aria-label={state.titleMode === "edit" ? "Edit document title" : "Document title"} contenteditable={state.titleMode === "edit"} oninput={titleInput} onkeydown={titleKeydown}>{state.document.title}</h1>
        {#if state.document.description}<p class="article-description">{state.document.description}</p>{/if}
      </div>
      <div class="title-actions">
        <IconButton icon={state.titleMode === "edit" ? "check" : "edit"} label={state.titleMode === "edit" ? "Validate title" : "Edit title"} onclick={() => {
          if (state.titleMode === "edit") dispatch({ type: "set-title-mode", mode: "preview" });
          else void editTitle();
        }} />
      </div>
    </div>

    <div class="details-panel" hidden={!state.detailsOpen}>
      {#if state.detailsOpen}
        <div class="details-grid">
          <input value={state.document.slug} aria-label="URL slug" placeholder="URL slug" oninput={(event) => setMetadata("slug", event)} />
          <textarea rows="2" value={state.document.description} aria-label="Short description" placeholder="Short description" oninput={(event) => setMetadata("description", event)}></textarea>
        </div>
      {/if}
    </div>

    <div class="article-toolbar"><span class="section-count">{sectionCount} section{sectionCount === 1 ? "" : "s"}</span></div>
    <div class="section-list" aria-live="polite">
      {#if sectionCount === 0}
        <p class="empty-state">Your article is empty. Add text or an image placeholder to begin.</p>
      {:else}
        {#each state.document.sections as section, index (section.id)}
          <SectionCard
            {section}
            {index}
            total={sectionCount}
            active={section.id === state.activeSectionId}
            mode={state.sectionModes.get(section.id) || "edit"}
            previewHtml={state.sectionPreviewHtml.get(section.id)}
            error={state.sectionErrors.get(section.id)}
            onActivate={() => dispatch({ type: "set-active-section", id: section.id })}
            onAction={(action) => handleSectionAction(section.id, action)}
            onFieldChange={(field, value) => {
              invalidateSection(section.id);
              dispatch({ type: "update-section", id: section.id, changes: { [field]: value } });
            }}
          />
        {/each}
      {/if}
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
    <span class="footer-note">Saving and publishing are separate operations and are not available in this shell.</span>
  </footer>
</main>
