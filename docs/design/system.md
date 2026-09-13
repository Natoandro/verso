# Verso — System Architecture

Deployment, technology, persistence, internal layering, and request paths.

This document is part of the [Verso architecture index](../design.md).

## 3. High-Level Architecture

Verso is primarily a single application.

```text
                         ┌───────────────────────┐
                         │        Editors        │
                         └───────────┬───────────┘
                                     │
                 ┌───────────────────┴───────────────────┐
                 │                                       │
             Web Browser                             AI Client
                 │                                       │
              HTTPS                                  MCP/HTTPS
                 │                                       │
                 └───────────────────┬───────────────────┘
                                     ▼
                         ┌───────────────────────┐
                         │         Verso         │
                         │                       │
                         │ Public web server     │
                         │ Admin/editor UI       │
                         │ MCP server            │
                         │ Auth                  │
                         │ Domain services       │
                         │ Renderer              │
                         │ Cache manager         │
                         │ Asset management      │
                         └───────────┬───────────┘
                                     │
                     ┌───────────────┴───────────────┐
                     ▼                               ▼
                  SQLite                         Asset store
                                                filesystem
                                                or S3-compatible
```

All interfaces operate through the same application/domain layer.

The web interface and MCP interface must never independently manipulate SQLite.

---

## 4. Initial Technology Direction

The implementation is intentionally experimental.

The initial target stack is:

```text
Language:              Zig
Database:              SQLite
Public rendering:      server-side HTML
Editorial frontend:    HTMX 4 + minimal JavaScript
Text content:          Markdown
Asset storage:         filesystem initially
Optional asset store:  S3-compatible storage / RustFS
Interactive content:   JavaScript and/or WASM
Page cache:            filesystem
Outer cache:           CDN / reverse proxy
AI integration:        remote MCP
MCP authentication:    OAuth-compatible authorization
```

SQLite, filesystem caching, and a single-process server are deliberate design choices rather than placeholders for a more complex architecture.

---

## 5. Deployment Model

The default deployment should be approximately:

```text
verso
verso.toml
data/
├── verso.db
├── assets/
└── cache/
```

A basic installation should require little more than:

```bash
verso init
verso serve
```

No separate database server is required.

A production environment may place a reverse proxy or CDN in front of Verso:

```text
Internet
   │
   ▼
Cloudflare / nginx / Caddy / Traefik
   │
   ▼
Verso
   │
   ├── SQLite
   ├── asset storage
   └── filesystem cache
```

Verso itself should not depend on a specific reverse proxy.

---

## 6. SQLite

SQLite is the sole database backend for the initial versions of Verso.

It stores canonical structured application state including:

```text
documents
sections
revisions

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

## 45. Internal Layering

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

```text
interfaces
    ↓
application
    ↓
domain
```

Infrastructure provides implementations needed by the application layer.

---

## 46. Request Paths

### Public request

```text
Browser
   │
   ▼
CDN
   │ miss
   ▼
Verso
   │
   ▼
filesystem cache
   │ miss
   ▼
SQLite
   │
   ▼
renderer
   │
   ▼
filesystem cache
   │
   ▼
response
```

---

### Draft editor request

```text
Browser
   │
   ▼
Verso
   │
   ├── authenticate
   ├── authorize
   │
   ▼
SQLite
   │
   ▼
editor response
```

No public page cache is involved.

---

### Live preview request

```text
Browser editor state
        │
        ▼
Verso preview endpoint
        │
        ▼
production renderer
        │
        ▼
HTML fragment
        │
        ▼
HTMX swap
```

No SQLite mutation is required.

---

### MCP edit

```text
AI client
    │
    ▼
OAuth-authenticated MCP
    │
    ▼
application service
    │
    ├── authorization
    ├── concurrency check
    ├── validation
    │
    ▼
SQLite
```

---
