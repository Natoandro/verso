# Verso — System Architecture

## Scope

This document defines Verso's runtime topology: the single application, its deployment shape, technology direction, persistence boundary, internal dependency direction, and representative request paths. It does not define the document schema, rendering rules, editor behavior, or identity policy.

Related: [content model](content.md), [rendering and cache](rendering.md), [web editor and preview](editor.md), and [identity and MCP](identity-and-mcp.md).

## 1. High-Level Architecture

Verso is primarily a single application.

```mermaid
flowchart TB
    editors["Editors"] --> browser["Web browser<br/>HTTPS"]
    editors --> ai["AI client<br/>MCP over HTTPS"]
    browser --> verso["Verso application"]
    ai --> verso
    verso --> sqlite[("SQLite<br/>canonical versioned state")]
    verso --> assets["Asset store<br/>filesystem initially"]
```

All interfaces operate through the same application/domain layer.

The web interface and MCP interface must never independently manipulate SQLite.

---

## 2. Initial Technology Direction

The implementation is intentionally experimental.

The initial target stack is:

```text
Language:              Zig
Database:              SQLite
Public rendering:      server-side HTML
Editorial frontend:    HTMX 4 + minimal JavaScript
Text content:          Markdown
Asset storage:         filesystem initially
Later asset store:     S3-compatible storage / RustFS
Interactive content:   planned; disabled pending security design
Page cache:            filesystem
Reverse proxy:         optional TLS forwarding, no response cache
AI integration:        remote MCP
MCP authentication:    OAuth-compatible authorization
```

SQLite, filesystem caching, and a single-process server are deliberate design choices rather than placeholders for a more complex architecture.

---

## 3. Deployment Model

The default deployment should be approximately:

```text
verso
verso.toml
data/
├── verso.db
├── assets/
└── cache/
```

A basic installation should require little more than a configuration file and
the server command:

```bash
verso config dump-default > verso.toml
verso serve
```

`config dump-default` writes a starter configuration to standard output and
does not create or modify files. `serve` creates the configured SQLite parent,
asset, and cache directories recursively when they are missing, then fails
with a clear startup error if a configured path cannot be prepared. This keeps
the first-run flow suitable for both local development and container images
with mounted data volumes.

No separate database server is required.

A production environment may place a TLS-terminating reverse proxy in front of
Verso. The initial design does not support a CDN or reverse-proxy response
cache; all application response caching remains inside Verso.

```mermaid
flowchart TB
    internet["Internet"] --> edge["Reverse proxy<br/>nginx / Caddy / Traefik"]
    edge --> verso["Verso"]
    verso --> sqlite[("SQLite")]
    verso --> assets["Asset storage"]
    verso --> cache["Filesystem cache"]
```

Verso itself should not depend on a specific reverse proxy.

---

## 4. SQLite

SQLite is the sole database backend for the initial versions of Verso.

It stores canonical structured application state including:

```text
document lineages and versions
sections and nested objects
working revisions

users
roles
permissions

authors
subjects
series

asset metadata
interactive module metadata

authentication data
OAuth authorization data
```

Large binaries should generally not be stored inside SQLite.

SQLite should normally operate in WAL mode for deployed instances.

```sql
PRAGMA journal_mode = WAL;
```

Verso should embrace SQLite rather than introduce premature abstractions for hypothetical PostgreSQL, MySQL, or other backends.

The domain/application layers should nevertheless avoid unnecessary coupling to SQL implementation details.

---

## 5. Internal Layering

A possible implementation structure is:

```text
src/
├── domain/
│   ├── document.zig
│   ├── section.zig
│   ├── revision.zig
│   ├── user.zig
│   └── permission.zig
│
├── application/
│   ├── documents.zig
│   ├── sections.zig
│   ├── publishing.zig
│   ├── revisions.zig
│   ├── preview.zig
│   └── assets.zig
│
├── storage/
│   ├── sqlite.zig
│   ├── filesystem.zig
│   └── object_store.zig
│
├── render/
│   ├── document.zig
│   ├── markdown.zig
│   ├── section.zig
│   ├── templates.zig
│   └── interactive.zig
│
├── cache/
│   └── filesystem.zig
│
├── auth/
│   ├── sessions.zig
│   ├── oauth.zig
│   └── permissions.zig
│
├── web/
│   ├── public/
│   └── admin/
│
├── mcp/
│
└── main.zig
```

This structure is illustrative rather than prescriptive.

The dependency direction should remain roughly:

```mermaid
flowchart TB
    interfaces["Interfaces"] --> application["Application services"]
    application --> domain["Domain model"]
    infrastructure["Infrastructure adapters"] --> application
```

Infrastructure provides implementations needed by the application layer.

---

## 6. Request Paths

### Public request

```mermaid
flowchart TB
    request["HTTP request"] --> verso["Verso"]
    verso --> cache["Filesystem page cache"]
    cache -->|miss| sqlite[("SQLite")]
    sqlite --> renderer["Renderer"]
    renderer --> cache
    cache --> response["Response"]
```

---

### Draft editor request

```mermaid
flowchart TB
    browser["Editor browser"] --> verso["Verso"]
    verso --> authenticate["Authenticate"]
    authenticate --> authorize["Authorize"]
    authorize --> sqlite[("SQLite")]
    sqlite --> response["Editor response"]
    response --> browser
    cache["Public page cache"] -. not used .-> response
```

---

### Live client preview

```mermaid
flowchart TB
    state["Browser unsaved state"] --> renderer["Client-side renderer"]
    renderer --> pane["Local preview pane"]
    renderer -. no mutation .-> sqlite[("SQLite")]
```

An explicit server preview is available only for a persisted draft. It follows
the same server rendering path as publication after editorial authorization,
but returns a private, noncached response and never changes the draft.

---

### MCP edit

```mermaid
flowchart TB
    ai["AI client"] --> mcp["OAuth-authenticated MCP"]
    mcp --> application["Application service"]
    application --> authorization["Authorization"]
    application --> concurrency["Version/revision check"]
    application --> validation["Validation"]
    validation --> sqlite[("SQLite")]
```

---
