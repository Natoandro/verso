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
* HTMX 4 for the editorial interface;
* client-side live previews with local draft recovery;
* server-rendered, publication-equivalent previews;
* filesystem caching of published pages;
* filesystem or S3-compatible storage for large assets;
* support for interactive JavaScript and WASM modules;
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
- [Content model](design/content.md) — documents, typed sections, assets,
  interactive modules, and revisions.
- [Rendering and cache](design/rendering.md) — server rendering, published
  page caching, invalidation, and draft-cache boundaries.
- [Web editor and preview](design/editor.md) — HTMX editing, client/server
  previews, local draft recovery, partial rendering, and stale-response
  protection.
- [Identity and MCP](design/identity-and-mcp.md) — users, permissions, OAuth,
  MCP tools, and optimistic concurrency.
- [Operations and boundaries](design/operations.md) — publication workflow,
  routes, configuration, UI customization, failure principles, non-goals,
  and the design philosophy.

## Cross-cutting invariants

These boundaries apply throughout the architecture:

- SQLite and the asset store are canonical publication state.
- Rendered HTML, filesystem caches, and CDN output are derived state.
- Local autosaved drafts are recoverable but noncanonical browser state; current
  unsaved changes and preview requests remain ephemeral runtime state.
- All interfaces use shared application/domain services.
- Preview, save, and publish are distinct operations.
- Published interactive modules are versioned and immutable.
