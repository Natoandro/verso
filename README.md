# Verso

Verso is a configurable, self-hosted publishing server for structured, rich,
and interactive content. It is intended for technical articles, research
notes, mathematical writing, essays, tutorials, image-rich documents, and
small multi-author publications.

The project is currently at the architecture/design stage. The architecture
index and topic specifications are linked from
[`docs/design.md`](docs/design.md).

## Planned architecture

Verso is designed as a small, single-process application with:

- a Zig server;
- SQLite as the initial and sole database backend;
- server-rendered public pages;
- structured documents made of ordered, typed sections;
- Markdown text sections;
- filesystem assets initially, with possible S3-compatible storage later;
- filesystem caching for published HTML;
- an HTMX 4 web editor with minimal JavaScript;
- server-rendered live previews using the publication renderer;
- versioned JavaScript/WASM interactive modules;
- remote MCP access for AI-assisted editing;
- OAuth-compatible authentication and capability-oriented authorization.

The web editor, MCP endpoint, and future interfaces are intended to share the
same domain and application services. They must not manipulate SQLite
independently.

## Content and state model

A document contains metadata and an ordered list of sections. Sections may be
text, image, interactive, quote, or other supported kinds. Canonical document
state lives in SQLite and binary assets live in the configured asset store.

Rendered HTML and CDN output are derived, disposable state. Unsaved editor
changes and preview requests are ephemeral state. This separation is central
to the design: cache failures must not damage publications, previews must not
save drafts, and publishing must be an explicit validated application
operation.

## Intended deployment

A basic deployment should eventually look approximately like this:

```text
verso
verso.toml
data/
├── verso.db
├── assets/
└── cache/
```

The target first-run workflow is:

```bash
verso init
verso serve
```

These commands describe the intended interface; they are not yet implemented
in this repository.

## Project status

There is no implementation, dependency manifest, test suite, or build command
checked into the repository yet. Avoid documenting speculative commands as
available functionality. When implementation begins, update this README and
the architecture specification together when behavior or design changes.

## Scope

Initial versions intentionally do not target PostgreSQL/MySQL support,
distributed server clusters, real-time character-level collaboration, CRDTs,
arbitrary scripts in the main page context, visual no-code page building,
generic relational-data construction, plugin marketplaces, complex workflow
engines, local MCP editing, or Git-based publishing/storage.
