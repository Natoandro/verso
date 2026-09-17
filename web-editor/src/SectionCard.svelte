<script lang="ts">
  import IconButton from "./IconButton.svelte";
  import { renderSection } from "./renderer";
  import type { Section } from "./model";
  import type { SectionMode } from "./state";

  let {
    section,
    index,
    total,
    mode,
    active,
    previewHtml,
    error,
    onActivate,
    onAction,
    onFieldChange,
  }: {
    section: Section;
    index: number;
    total: number;
    mode: SectionMode;
    active: boolean;
    previewHtml?: string;
    error?: string;
    onActivate: () => void;
    onAction: (action: "move-up" | "move-down" | "duplicate" | "delete" | "validate-section" | "edit-section") => void;
    onFieldChange: (field: "markdown" | "asset" | "alt" | "caption", value: string) => void;
  } = $props();

  function cardClick(event: MouseEvent): void {
    if (!(event.target as HTMLElement).closest("button")) onActivate();
  }

  function cardKeydown(event: KeyboardEvent): void {
    if ((event.key === "Enter" || event.key === " ") && event.target === event.currentTarget) {
      event.preventDefault();
      onActivate();
    }
  }

  function value(event: Event): string {
    return (event.currentTarget as HTMLInputElement | HTMLTextAreaElement).value;
  }
</script>

<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<article class:is-active={active} class="section-card {section.kind}-section" tabindex="0" onclick={cardClick} onkeydown={cardKeydown}>
  <div class="section-actions">
    <IconButton icon="up" label="Move section up" disabled={index === 0} dataSectionAction onclick={() => onAction("move-up")} />
    <IconButton icon="down" label="Move section down" disabled={index === total - 1} dataSectionAction onclick={() => onAction("move-down")} />
    <IconButton icon="copy" label="Duplicate section" dataSectionAction onclick={() => onAction("duplicate")} />
    <IconButton icon="delete" label="Delete section" dataSectionAction onclick={() => onAction("delete")} />
    <IconButton icon={mode === "preview" ? "edit" : "check"} label={mode === "preview" ? "Edit section" : "Validate section"} dataSectionAction onclick={() => onAction(mode === "preview" ? "edit-section" : "validate-section")} />
  </div>

  {#if mode === "preview"}
    <div class="section-card-body section-preview">
      <!-- This is the existing safe local renderer output; raw editor input never reaches this block. -->
      {@html previewHtml || renderSection(section)}
    </div>
  {:else}
    <div class="section-card-body section-editor">
      {#if section.kind === "text"}
        <div class="growing-textarea" data-replicated-value={section.markdown}>
          <textarea value={section.markdown} aria-label="Markdown content" spellcheck="false" oninput={(event) => onFieldChange("markdown", value(event))}></textarea>
        </div>
      {:else}
        <div class="image-editor">
          <div class="asset-note">Image upload is not part of the unsaved editor yet.</div>
          <div class="image-fields">
            <input type="text" value={section.asset} placeholder="Asset name" aria-label="Asset name" oninput={(event) => onFieldChange("asset", value(event))} />
            <input type="text" value={section.alt} placeholder="Alt text" aria-label="Alt text" oninput={(event) => onFieldChange("alt", value(event))} />
          </div>
          <input type="text" value={section.caption} placeholder="Caption" aria-label="Caption" oninput={(event) => onFieldChange("caption", value(event))} />
        </div>
      {/if}
      {#if error}<p class="validation-error">{error}</p>{/if}
    </div>
  {/if}
</article>
