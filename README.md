# Verso

Verso is a configurable, self-hosted publishing server for structured, rich,
and interactive content. It is intended for technical articles, research
notes, mathematical writing, essays, tutorials, image-rich documents, and
small multi-author publications.

The project is in early implementation. The architecture index and topic
specifications are linked from
[`docs/design.md`](docs/design.md).

## License

Verso is free software licensed under the GNU Affero General Public License,
version 3 only (`AGPL-3.0-only`). See [`LICENSE`](LICENSE) for the complete
license text. User-created publications and assets remain the property of
their respective authors and operators and are not covered by this license.

## Planned architecture

Verso is designed as a small, single-process application with:

- a Zig server;
- SQLite as the initial and sole database backend;
- server-rendered public pages;
- structured documents made of ordered, typed sections;
- Markdown text sections;
- filesystem assets initially, with possible S3-compatible storage later;
- filesystem caching for published HTML;
- an HTMX 4-oriented web editor with a Svelte + TypeScript island limited to
  the browser-local editing surface;
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
verso migrate up
verso serve
```

For persistent customization, an operator can generate a starter file:

```bash
verso config dump-default > verso.toml
verso serve
```

`config dump-default` prints a starter configuration without writing files.
The server uses built-in defaults when `verso.toml` is absent and creates its
configured runtime directories during startup.

See [`docs/design/operations.md`](docs/design/operations.md) for migration,
configuration, deployment, and logging details.

## Development

Implementation work and progress are tracked in
[`docs/implementation-plan.md`](docs/implementation-plan.md) and the dedicated
[template-engine implementation plan](docs/template-engine-implementation-plan.md).
Commands shown above may still expose partial behavior until their corresponding
plan entries are complete and verified. Run `zig build test` for unit tests and
`zig build verify` for the executable bootstrap flows.

The editor frontend is bundled automatically by `zig build` using the locked
dependencies in `web-editor/pnpm-lock.yaml`. Install them once with
`corepack pnpm install --dir web-editor`; the released Zig binary embeds the
generated assets and does not require Node at runtime.

## Scope

Initial versions intentionally do not target PostgreSQL/MySQL support,
distributed server clusters, real-time character-level collaboration, CRDTs,
arbitrary scripts in the main page context, visual no-code page building,
generic relational-data construction, plugin marketplaces, complex workflow
engines, local MCP editing, or Git-based publishing/storage.
