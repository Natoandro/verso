<script lang="ts">
  import CheckIcon from "./icons/CheckIcon.svelte";
  import CopyIcon from "./icons/CopyIcon.svelte";
  import DeleteIcon from "./icons/DeleteIcon.svelte";
  import DetailsIcon from "./icons/DetailsIcon.svelte";
  import DownIcon from "./icons/DownIcon.svelte";
  import EditIcon from "./icons/EditIcon.svelte";
  import ImageIcon from "./icons/ImageIcon.svelte";
  import PlusIcon from "./icons/PlusIcon.svelte";
  import TextIcon from "./icons/TextIcon.svelte";
  import UpIcon from "./icons/UpIcon.svelte";
  import type { IconName } from "./icons/types";
  let {
    icon,
    label,
    disabled = false,
    pressed = undefined,
    dataSectionAction = false,
    onclick,
  }: {
    icon: IconName;
    label: string;
    disabled?: boolean;
    pressed?: boolean;
    dataSectionAction?: boolean;
    onclick: () => void;
  } = $props();

  let buttonClass = $derived(`icon-button icon-button-${icon}`);
</script>

<button type="button" class={buttonClass} title={label} aria-label={label} aria-pressed={pressed} disabled={disabled} data-section-action={dataSectionAction ? "" : undefined} {onclick}>
  <span class="icon" aria-hidden="true">
    {#if icon === "check"}<CheckIcon />
    {:else if icon === "copy"}<CopyIcon />
    {:else if icon === "delete"}<DeleteIcon />
    {:else if icon === "details"}<DetailsIcon />
    {:else if icon === "edit"}<EditIcon />
    {:else if icon === "image"}<ImageIcon />
    {:else if icon === "plus"}<PlusIcon />
    {:else if icon === "text"}<TextIcon />
    {:else if icon === "up"}<UpIcon />
    {:else}<DownIcon />
    {/if}
  </span>
</button>
