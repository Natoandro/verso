# Verso — Editor Architecture Alternatives

## Purpose

Verso's document model is section-oriented, but that does not by itself
require an offline-first browser editor. This note compares two possible web
editor strategies:

1. a pure HTMX, server-transactional editor; and
2. the current HTMX shell with an offline-capable Svelte editor island.

The comparison is intended to keep the section model separate from the choice
of where unsaved editor state lives.

## Shared foundation

Both approaches use the same canonical architecture:

- documents contain ordered, typed sections;
- published and archived versions are immutable;
- mutable drafts are persisted through application services;
- authorization, validation, optimistic concurrency, and cache invalidation
  remain server-side concerns;
- the server renderer remains authoritative for publication and
  publication-equivalent previews;
- public routes never expose draft state.

Sectioning is useful independently of offline editing. It provides stable
identities and typed boundaries for validation, rendering, reordering,
duplication, deletion, asset ownership, AI/MCP operations, and future
section-level features. It also makes targeted HTMX mutations practical.

## Alternative A: pure HTMX editor

“Pure HTMX” means that the editor has no application-specific client-side
document model. HTMX itself still uses JavaScript in the browser, but the
server owns the working draft and returns HTML fragments.

### Interaction model

1. The server renders the draft and its section fragments.
2. An editor opens a section as an HTML form.
3. An explicit action submits a section mutation or document operation.
4. The application service validates and persists the operation.
5. The server returns the updated section, document region, or validation
   errors.
6. HTMX swaps the returned fragment into the page.

Preview is produced from persisted draft state. A section can be validated and
previewed after its operation is saved, while a complete private preview uses
the normal server renderer against the persisted draft.

### Advantages

- Minimal frontend code and dependency surface.
- Server-rendered HTML is the normal editor representation.
- No client/server document-state synchronization layer.
- No duplicate local Markdown renderer is required for the initial editor.
- Authorization and validation remain close to the mutation boundary.
- Browser state is easy to discard, inspect, and reproduce.
- Works well with ordinary forms, accessibility tooling, and browser history.
- Section-level operations map naturally to small HTMX requests and
  application-service calls.
- A released binary does not need to ship a substantial editor runtime.

### Costs and limitations

- Most editing operations require a network round trip.
- Preview-before-save either is unavailable or requires a transient preview
  endpoint that accepts unsaved content.
- Reordering many sections or making several edits can feel slow without
  careful batching and response design.
- The server must return enough surrounding HTML to keep document order,
  controls, focus, and validation messages correct.
- A tab crash or lost connection can lose edits since the last successful
  request unless a separate recovery mechanism is added.
- Offline editing is not available.
- “Pure” does not mean zero JavaScript: HTMX, focus management, and any
  optional recovery enhancement still require browser code.

### Best fit

This approach fits an online-first publishing CMS where explicit section saves
and server-rendered previews are acceptable, and where simplicity and
publication parity matter more than a document-editor-like interaction model.

## Alternative B: offline-capable Svelte editor island

The current design keeps HTMX for the surrounding editorial application and
mounts Svelte only below a stable editor root. Svelte owns a browser-local
structured draft, section presentation state, provisional preview rendering,
and local recovery. Server operations still go through the application
services and remain canonical.

### Interaction model

1. The browser loads or creates a structured local draft.
2. Svelte applies section operations locally: edit, validate, reorder,
   duplicate, and delete.
3. A compatible client renderer provides an immediate provisional preview.
4. A debounced browser snapshot may be stored in IndexedDB or a fallback
   browser store.
5. An explicit save sends the complete draft, with its expected server
   revision, to the protected application boundary.
6. The server accepts or rejects the save; stale revisions require explicit
   reconciliation.
7. An explicit persisted-draft preview uses the authoritative server renderer.

### Advantages

- Immediate editing and preview without a request for every operation.
- Can continue composing during connectivity loss.
- Browser-local recovery can survive crashes, restarts, and interrupted
  sessions.
- Rich interactions such as drag/reorder and inline mode changes are easier to
  implement coherently.
- The editor can show a complete local document before its first server save.
- Local validation and preview can provide fast feedback while preserving the
  server as the security and publication authority.

### Costs and limitations

- Larger frontend dependency and testing surface.
- A client-side document model and reducer must remain consistent with the
  server document model.
- The client renderer and server renderer need compatible semantics and safe
  Markdown/URL handling.
- Recovery introduces namespace, identity, storage-failure, restore, merge,
  discard, and stale-revision cases.
- Offline work can become difficult to reconcile with server edits and
  version lineage.
- Asset selection, uploads, authentication expiry, and server-only rendering
  features need explicit offline behavior.
- The browser experience can expose more transient state than the server knows
  about, so the UI must keep local state, persisted drafts, and published state
  visibly distinct.

### Best fit

This approach fits a long-form editor where losing a local working session is
costly, where immediate preview and manipulation are central to the product,
or where unreliable connectivity is an expected operating condition.

## Comparison

| Concern | Pure HTMX | Svelte editor island |
| --- | --- | --- |
| Canonical persistence | Server draft operations | Server draft saves and operations |
| Unsaved state | Browser form state | Structured browser-local state |
| Preview before save | Not naturally available | Immediate provisional preview |
| Persisted preview | Server renderer | Server renderer |
| Offline editing | No | Yes, within defined limits |
| Crash recovery | Requires a separate enhancement | Built into the local snapshot model |
| Network usage | Frequent, often section-level | Mostly on load/save/explicit actions |
| Rendering implementation | Primarily server-side | Compatible client and server renderers |
| Frontend complexity | Low | Medium to high |
| Concurrency UX | Smaller server mutations | Complete-draft reconciliation is required |
| Section model required | Useful and sufficient | Useful and required for local operations |

## Decision boundary

Sectioning does not decide between these approaches. The deciding question is
where the working document lives before an explicit save:

- If the server owns it, HTMX is sufficient.
- If the browser owns it temporarily, a client-side application model is
  required; Svelte is one implementation, while vanilla TypeScript is another.

The offline requirement should therefore be treated as a product decision,
not as an implicit consequence of typed sections.

## Recommendation for the initial release

Unless Verso has a confirmed requirement for unreliable-network or
long-session editing, prefer an online-first, section-oriented HTMX editor for
the initial release:

- keep ordered typed sections;
- save section operations through application services;
- return server-rendered HTMX fragments;
- preview persisted drafts with the authoritative server renderer;
- defer offline editing and browser-local recovery;
- keep the option to add a client-side editor island later.

If recovery is later shown to be necessary, it can be added as a bounded
enhancement without changing canonical storage: first add a small local
snapshot mechanism, then consider richer local preview or offline editing only
if real usage justifies the additional synchronization and rendering cost.

