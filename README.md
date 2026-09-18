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
- an HTMX 4-oriented, server-transactional web editor for ordered sections;
- server-rendered, publication-equivalent previews of persisted drafts;
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

Rendered HTML is derived, disposable state, while draft and published content
remain canonical server state. This separation is central to the design: cache
failures must not damage publications, and publishing must be an explicit
validated application operation.

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
VERSO_BOOTSTRAP_PASSWORD='use-a-secret-manager' verso auth bootstrap-owner \
  --login owner@example.test \
  --subject local-owner \
  --display-name 'Site Owner'
verso serve
```

`auth bootstrap-owner` is one-time and reads the initial password from
`VERSO_BOOTSTRAP_PASSWORD`; recovery-token delivery is intentionally deferred
until an email or other configured delivery channel exists.

First-user setup is intentionally a single-use boundary. The setup surface
supports web registration from the empty-database login page and an optional
`[auth.bootstrap]` configuration/environment record. These paths
share one atomic owner-provisioning service; whichever succeeds first closes
the setup window, and later attempts cannot create another initial user. When
OIDC is implemented, script and configuration provisioning may omit local
credentials and use a verified-email handoff instead; an email value alone is
never treated as authentication. See
[`docs/design/identity-and-mcp.md`](docs/design/identity-and-mcp.md) and
[`docs/implementation-plan.md`](docs/implementation-plan.md) for the first-user
flow and its security boundary.

### Docker

The local Compose setup builds the server image, persists SQLite/assets/cache in
a named volume, and publishes the server at <http://localhost:8080>:

```bash
docker compose up --build
```

The image defaults to development settings for local use. For a production
deployment, set `VERSO_RUNTIME_ENVIRONMENT=production` and provide a public,
non-loopback `VERSO_SITE_BASE_URL`.

For persistent customization, an operator can generate a starter file:

```bash
verso config dump-default > verso.toml
verso serve
```

`config dump-default` prints a starter configuration without writing files.
The server uses built-in defaults when `verso.toml` is absent and creates its
configured runtime directories during startup.

`verso config env-reference` prints the reflected `VERSO_*` environment
variable names and their configuration paths.

One-off configuration values may be supplied after the command, or before the
command for the shared `--config` selector:

```bash
verso --config /etc/verso/production.toml serve --server-port 9090
```

Configuration precedence is built-in defaults, optional file, environment,
then command line. The `serve` CLI surface is generated from the canonical
configuration schema plus sparse CLI metadata; it does not maintain a second
list of configuration fields. Typed values are strict: booleans are
`true` or `false`, enums use their documented lowercase names, and integers
use decimal notation. Database URLs may be supplied with `--database-url`,
but are never included in configuration diagnostics. The temporary document
bootstrap commands are specified by DOC-001 and DOC-002 rather than by this
CLI schema.

See [`docs/design/operations.md`](docs/design/operations.md) for migration,
configuration, deployment, and logging details.

## Development

Implementation work and progress are tracked in
[`docs/implementation-plan.md`](docs/implementation-plan.md) and the dedicated
[template-engine implementation plan](docs/template-engine-implementation-plan.md).
Commands shown above may still expose partial behavior until their corresponding
plan entries are complete and verified. Run `zig build test` for unit tests and
`zig build verify` for the executable bootstrap flows.

The editor is served from the server-rendered web interface and does not
require a separate frontend build or Node.js at runtime.

## Scope

Initial versions intentionally do not target PostgreSQL/MySQL support,
distributed server clusters, real-time character-level collaboration, CRDTs,
arbitrary scripts in the main page context, visual no-code page building,
generic relational-data construction, plugin marketplaces, complex workflow
engines, local MCP editing, or Git-based publishing/storage.
