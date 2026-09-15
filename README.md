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
- client-side previews with local draft autosave and explicit server-rendered,
  publication-equivalent previews of persisted drafts;
- immutable, explicitly numbered document versions with read-only archives;
- planned, versioned JavaScript/WASM interactive modules, disabled until their
  security design is specified;
- remote MCP access for AI-assisted editing;
- OAuth-compatible authentication and capability-oriented authorization.

The web editor, MCP endpoint, and future interfaces are intended to share the
same domain and application services. They must not manipulate SQLite
independently.

## Content and state model

A logical document contains an explicitly numbered sequence of versions. Each
version owns metadata and an ordered list of sections, which may be text,
image, interactive, quote, or other supported kinds. Published and archived
versions are immutable. Editing a published version creates an explicitly
linked next-version draft by logically deep-copying all sections and owned
nested objects; publishing it archives the old version and makes the new one
current. Archived versions remain read-only and publicly accessible by default,
unless the author disables their archive visibility. Canonical document state
lives in SQLite and binary assets live in the configured asset store.

Only the current published version may be the source of a next-version draft;
unpublished drafts cannot be forked in the initial design.

Rendered HTML is derived, disposable state. Local autosaved drafts are
recoverable but noncanonical browser state, while current unsaved changes and
client-side previews are ephemeral runtime state. This separation is
central to the design: cache failures must not damage publications, local
recovery must not silently save drafts to Verso, and publishing must be an
explicit validated application operation.

## Intended deployment

A basic deployment should eventually look approximately like this:

```text
verso
verso.toml (optional)
data/
├── verso.db
├── assets/
└── cache/
```

The simplest first-run workflow is:

```bash
verso serve
```

For persistent customization, an operator can generate a starter file:

```bash
verso config dump-default > verso.toml
verso serve
```

`config dump-default` prints a starter configuration without writing files.
The server uses built-in defaults when `verso.toml` is absent. Command-line
configuration options are planned to take precedence over environment
variables, the optional configuration file, and built-in defaults.
`serve` creates missing configured data, asset, and cache directories during
startup, runs each accepted request through the threaded Zig I/O runtime, and
writes one structured log record per request to standard error. The logging
framework accepts arbitrary structured records and adds an ISO-8601 UTC
timestamp at write time. Logging defaults to JSON in production and to pretty
output with terminal colors for development TTYs (or plain text when stderr is
redirected). The
server runtime remains incomplete; its remaining work is tracked in the
implementation plan.

## Development

Implementation work and progress are tracked in
[`docs/implementation-plan.md`](docs/implementation-plan.md). Commands shown
above may still expose partial behavior until their corresponding plan entries
are complete and verified.

## Scope

Initial versions intentionally do not target PostgreSQL/MySQL support,
distributed server clusters, real-time character-level collaboration, CRDTs,
arbitrary scripts in the main page context, visual no-code page building,
generic relational-data construction, plugin marketplaces, complex workflow
engines, local MCP editing, or Git-based publishing/storage.
