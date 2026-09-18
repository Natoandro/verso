# Verso — System Architecture

This file is the index for Verso's architecture documentation. The detailed
specification is organized by concern so each document can be read
independently while preserving the design's shared vocabulary and boundaries.

## 1. Overview

Verso is a configurable, self-hosted publishing system for structured, rich, and interactive content.

It is designed for publications such as:

* technical articles;
* research notes;
* mathematical writing;
* essays;
* tutorials;
* image-rich documents;
* interactive articles;
* small multi-author publications.

Verso is intended to be distributed primarily as a standalone native binary with configuration-driven customization.

The initial implementation focuses on:

* server-side rendered public pages;
* structured documents composed of typed sections;
* an online web editor;
* AI-assisted editing through a remote MCP server;
* SQLite as the sole database backend;
* HTMX 4 for the editorial interface, with server-transactional section
  editing;
* server-rendered previews of persisted drafts;
* filesystem caching of published pages;
* filesystem storage for large assets, with S3-compatible storage deferred to a
  later version;
* planned support for interactive JavaScript and WASM modules, disabled until
  their security design is specified;
* configurable publication appearance and behavior.

Verso is not tied to any particular publication.

A site such as Bracket is simply one deployment of Verso.

---

## 2. Architectural Goals

Verso should prioritize:

1. **Simple deployment**
2. **Minimal infrastructure**
3. **Structured content**
4. **Strong server-side rendering**
5. **Excellent cacheability**
6. **Safe multi-editor workflows**
7. **First-class AI editing**
8. **Portable content**
9. **Predictable behavior**
10. **Architectural simplicity over premature abstraction**

The initial system should deliberately avoid generalizing for hypothetical future databases, distributed clusters, or plugin systems unless actual requirements justify them.

---

## Architecture map

- [System architecture](design/system.md) — deployment model, technology
  direction, SQLite, internal layering, and representative request paths.
- [Routing and static delivery](design/routing.md) — comptime route patterns,
  composable routing layers, matching precedence, and static handlers.
- [Content model](design/content.md) — document versions, typed sections,
  assets, interactive modules, working revisions, and portable exchange
  archives.
- [Rendering and cache](design/rendering.md) — server rendering, published
  page caching, invalidation, and draft-cache boundaries.
- [Compile-time markup templates](design/template-engine.md) — typed,
  developer-authored Zig templates, comptime validation, components, and
  writer-based HTML rendering.
- [Web editor and preview](design/editor.md) — HTMX-oriented section editing
  and server-rendered previews of persisted drafts.
- [Editor architecture alternatives](design/editor-approaches.md) — deferred
  editor alternatives and the rationale for the current HTMX direction.
- [Identity and MCP](design/identity-and-mcp.md) — users, permissions, OAuth,
  MCP tools, and optimistic concurrency.
- [Operations and boundaries](design/operations.md) — publication workflow,
  routes, configuration, UI customization, failure principles, non-goals,
  and the design philosophy.

## Cross-cutting invariants

These boundaries apply throughout the architecture:

- SQLite and the asset store are canonical publication state.
- Rendered HTML and filesystem caches are derived state.
- Local autosaved drafts are recoverable but noncanonical browser state; current
  unsaved changes and preview requests remain ephemeral runtime state.
- All interfaces use shared application/domain services.
- Preview, save, and publish are distinct operations.
- Published interactive modules are versioned and immutable.
- Published document versions are immutable; editing one creates an explicitly
  linked next-version draft through a deep copy of its sections and owned
  objects.
- A next-version draft may be based only on the current published version;
  unpublished drafts cannot be forked in the initial design.
- Publishing a next version atomically archives the previous published version
  and makes the new version current; archived versions remain read-only and
  are publicly accessible by default unless archive visibility is disabled.
- A manager may irrevocably finalize a published document with no mutable
  version. Finalization closes the lineage and permits immutable client caching
  of that document's fixed public routes and version-scoped assets.
- Document exchange archives contain a complete version snapshot, its ordered
  sections, and required asset bytes; optional presentation bundles may carry
  the selected theme for authorized local previews; imports assign local
  identities and always produce draft state.
