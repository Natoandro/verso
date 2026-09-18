<svelte:options runes={true} />

<script lang="ts">
  import { createDocumentTransport, DocumentTransportError, type DocumentSummary } from "./transport";

  const transport = createDocumentTransport();
  let documents = $state.raw<DocumentSummary[]>([]);
  let phase = $state.raw<"loading" | "ready" | "creating" | "error">("loading");
  let message = $state("Loading documents…");
  let title = $state("");
  let slug = $state("");
  let initialized = false;

  async function loadDocuments(): Promise<void> {
    phase = "loading";
    message = "Loading documents…";
    try {
      documents = await transport.listDocuments();
      phase = "ready";
      message = documents.length === 0 ? "No editable drafts yet." : "";
    } catch (error) {
      phase = "error";
      message = error instanceof Error ? error.message : "Documents could not be loaded";
    }
  }

  async function createDraft(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!title.trim() || !slug.trim()) {
      message = "Enter a title and URL slug before creating a draft.";
      return;
    }
    phase = "creating";
    message = "Creating draft…";
    try {
      const draft = await transport.createDraft({ title: title.trim(), slug: slug.trim() });
      window.location.href = `/admin/editor?document=${encodeURIComponent(draft.documentId)}`;
    } catch (error) {
      phase = "error";
      message = error instanceof DocumentTransportError && error.status === 409
        ? "A mutable draft already exists for this document. Open it from the list."
        : error instanceof Error ? error.message : "Draft could not be created";
    }
  }

  $effect(() => {
    if (initialized) return;
    initialized = true;
    void loadDocuments();
  });
</script>

<main class="admin-page">
  <header class="admin-page-header">
    <div>
      <p class="eyebrow">Verso</p>
      <h1>Documents</h1>
      <p class="admin-lede">Drafts assigned to your editorial account.</p>
    </div>
    <a class="admin-link" href="/admin/editor">Local editor</a>
  </header>

  <section class="admin-create-card" aria-labelledby="create-draft-heading">
    <h2 id="create-draft-heading">Create a draft</h2>
    <form onsubmit={createDraft}>
      <label>Title <input value={title} oninput={(event) => title = (event.currentTarget as HTMLInputElement).value} autocomplete="off" /></label>
      <label>URL slug <input value={slug} oninput={(event) => slug = (event.currentTarget as HTMLInputElement).value} autocomplete="off" /></label>
      <button type="submit" disabled={phase === "creating"}>Create draft</button>
    </form>
  </section>

  <section class="admin-document-list" aria-labelledby="document-list-heading" aria-live="polite">
    <div class="admin-section-heading">
      <h2 id="document-list-heading">Your drafts</h2>
      <button type="button" class="quiet-button" onclick={() => void loadDocuments()} disabled={phase === "loading"}>Refresh</button>
    </div>
    {#if phase === "loading"}<p class="admin-state">{message}</p>
    {:else if phase === "error"}<p class="admin-state admin-error">{message}</p>
    {:else if documents.length === 0}<p class="admin-state">{message}</p>
    {:else}
      <ul>
        {#each documents as item (item.documentId)}
          <li>
            <div>
              <strong>{item.title}</strong>
              <span>/{item.slug} · revision {item.workingRevision}</span>
            </div>
            <a class="admin-link" href={`/admin/editor?document=${encodeURIComponent(item.documentId)}`}>Open draft</a>
          </li>
        {/each}
      </ul>
    {/if}
  </section>
</main>
