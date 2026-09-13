# Verso — System Architecture Overview

## 1. Purpose

Verso is a configurable, self-hosted publishing system for structured and interactive content.

It is designed primarily for long-form publications such as:

* technical articles;
* research notes;
* mathematical writing;
* essays;
* tutorials;
* image-rich articles;
* articles containing interactive components.

Verso is intended to be distributed as a standalone binary with configuration-driven customization.

The initial implementation focuses on:

* server-side rendered public pages;
* a web-based editorial interface;
* AI-assisted editing through an MCP server;
* SQLite as the sole database backend;
* structured document sections rather than monolithic article bodies;
* filesystem and CDN caching for rendered pages;
* optional object storage for media and executable assets.

Verso is not tied to any particular publication or website.

---

## 2. Core Architectural Principles

### 2.1 Single application

Verso should initially be deployable as one server application:

```text
                ┌─────────────────────────┐
                │          Verso          │
                │                         │
HTTP ──────────►│ Public site             │
HTTP ──────────►│ Web editor              │
MCP  ──────────►│ MCP server              │
                │                         │
                │ Domain services         │
                │ Renderer                │
                │ Cache manager           │
                │ Storage services        │
                └────────────┬────────────┘
                             │
                           SQLite
```

The public website, editorial interface, MCP interface, rendering engine, and persistence layer should share the same domain model and application services.

No interface should directly manipulate the database independently.

---

### 2.2 SQLite-first

SQLite is the only database backend targeted initially.

A Verso deployment should require approximately:

```text
verso
verso.toml
verso.db
assets/
cache/
```

This keeps deployment and self-hosting simple.

SQLite stores structured application data including:

* users;
* roles and permissions;
* documents;
* sections;
* revisions;
* publication state;
* authors;
* subjects;
* series;
* asset metadata;
* interactive-module metadata;
* MCP/OAuth authorization data.

Large binary objects should normally not be stored directly inside SQLite.

---

### 2.3 Structured documents

The primary content unit is a `Document`.

An article is one possible document type rather than the fundamental storage abstraction.

Conceptually:

```text
Document
├── metadata
└── ordered sections
    ├── text
    ├── image
    ├── interactive
    ├── embed
    ├── quote
    └── other future section types
```

This allows Verso to support richer publications without requiring arbitrary HTML or MDX as the canonical content representation.

---

## 3. Domain Model

### 3.1 Document

A document contains metadata such as:

```text
id
type
slug
title
description
status
created_at
updated_at
published_at
created_by
```

Possible statuses include:

```text
draft
review
scheduled
published
archived
```

Additional metadata may depend on the configured document type.

For example, an `article` may define:

```text
authors
subjects
series
series_position
```

---

### 3.2 Sections

Each document contains an ordered list of sections.

A section has a common envelope:

```text
id
document_id
position
kind
data
```

`data` contains section-specific structured data.

For example:

#### Text section

```json
{
  "markdown": "Let $K/\\mathbb{Q}$ be a number field..."
}
```

#### Image section

```json
{
  "asset_id": "asset-id",
  "alt": "Description of the figure",
  "caption": "Prime decomposition in a quadratic field"
}
```

#### Interactive section

```json
{
  "module_id": "monte-carlo-area",
  "version": 2,
  "config": {
    "samples": 5000
  }
}
```

The renderer should map these section types to HTML without exposing storage-specific details.

---

## 4. Rendering Architecture

Verso uses server-side rendering.

A request follows approximately:

```text
HTTP request
     │
     ▼
CDN cache
     │ miss
     ▼
Verso page cache
     │ miss
     ▼
load document from SQLite
     │
     ▼
render sections
     │
     ▼
render page template
     │
     ▼
cache generated HTML
     │
     ▼
response
```

Rendered HTML is a derived artifact.

It must always be possible to delete the cache and regenerate pages from canonical content.

---

## 5. Caching

Verso should distinguish between at least three cache levels:

```text
1. CDN / reverse-proxy cache
2. filesystem HTML cache
3. optional in-memory cache
```

The initial implementation may omit the in-memory layer if unnecessary.

### 5.1 Cache invalidation

Cache invalidation should be event-driven rather than based primarily on short expiration times.

Publishing or modifying a document may invalidate:

```text
/document/:slug
/
/series/:slug
/subject/:slug
/feed
/sitemap
```

Only affected derived pages should need regeneration.

---

## 6. Storage

### 6.1 SQLite

SQLite is the canonical store for structured content and metadata.

Recommended concepts include:

```text
documents
sections
document_revisions
users
roles
permissions
authors
subjects
series
assets
interactive_modules
oauth_clients
oauth_tokens
```

The exact relational schema is implementation-specific and may evolve.

SQLite should preferably operate in WAL mode for deployed instances.

---

### 6.2 Assets

Binary assets should live outside the primary database.

Supported storage may initially include:

```text
local filesystem
```

and later:

```text
S3-compatible object storage
RustFS
```

Examples:

```text
images
PDFs
datasets
downloadable files
JavaScript bundles
WASM modules
```

SQLite stores their metadata and identifiers.

---

## 7. Interactive Content

Interactive sections should not normally contain arbitrary inline scripts executed in the main document context.

The preferred model is a versioned interactive module:

```text
interactive module
├── id
├── version
├── script asset
├── optional stylesheet
├── optional WASM asset
└── configuration schema
```

A document section references the module:

```json
{
  "module_id": "prime-factorization",
  "version": 3,
  "config": {
    "field": "Q(sqrt(5))"
  }
}
```

This provides:

* reproducibility;
* version stability;
* caching;
* controlled execution;
* easier review;
* safer multi-editor operation.

If arbitrary user-provided HTML/CSS/JavaScript is supported later, it should execute inside an appropriately sandboxed iframe rather than the main page context.

---

## 8. Web Editing

Verso provides an authenticated web interface for editing.

The web application should use the same domain services as other interfaces.

Conceptually:

```text
Browser
   │
   ▼
Web handlers
   │
   ▼
Application services
   │
   ├── authorization
   ├── validation
   ├── revision handling
   ├── publishing
   └── cache invalidation
   │
   ▼
SQLite
```

The UI may expose documents as ordered blocks:

```text
Article

[ Text section ]
[ Image section ]
[ Text section ]
[ Interactive section ]

+ Add section
```

Sections can be created, edited, reordered, or removed.

---

## 9. Revision Model

Published content should have recoverable history.

Verso may keep normalized current content while storing immutable revision snapshots.

Conceptually:

```text
current document
    │
    ├── metadata
    └── sections

revision
    │
    └── complete document snapshot
```

A revision records:

```text
revision_id
document_id
revision_number
snapshot
editor_id
created_at
```

This avoids requiring independent temporal history for every section row.

Revision creation policy may be configurable, for example:

```text
on explicit save
on publish
periodic autosave checkpoint
```

---

## 10. Authentication and Authorization

Verso has a unified user identity model shared by:

* web editing;
* MCP editing;
* future APIs.

Possible roles include:

```text
owner
editor
author
contributor
```

Internally, permissions should preferably be capability-based, for example:

```text
document:create
document:read:any
document:update:self
document:update:any
document:review
document:publish
asset:upload
user:manage
```

Roles are collections of permissions.

Application services must perform authorization checks regardless of the interface making the request.

---

## 11. MCP Architecture

MCP is a first-class remote interface for AI-assisted editorial work.

The MCP server runs as part of the Verso application:

```text
AI client
    │
    │ MCP over HTTPS
    ▼
Verso MCP endpoint
    │
    ▼
authentication
    │
    ▼
authorization
    │
    ▼
application services
    │
    ▼
SQLite
```

MCP must never bypass the application service layer or manipulate SQLite directly.

---

## 12. MCP Authentication

Remote MCP access should use OAuth-compatible authentication.

A typical flow is:

```text
AI client
    │
    ▼
Verso MCP resource
    │
    ▼
authorization discovery
    │
    ▼
user authenticates
    │
    ▼
client receives access token
    │
    ▼
MCP requests with bearer token
```

The authenticated MCP identity maps to a normal Verso user.

Therefore:

```text
MCP permissions == user permissions
```

An AI agent operating on behalf of an author must not acquire editor or owner privileges simply because it accesses the MCP interface.

---

## 13. MCP Scopes

OAuth scopes may provide an additional authorization layer.

Possible scopes include:

```text
content:read
content:write
content:review
content:publish

assets:read
assets:write
```

A common authorization grant may intentionally exclude publication:

```text
content:read
content:write
```

This allows an AI client to assist with drafting while requiring a human or separately authorized operation for publication.

---

## 14. MCP Tools

The MCP interface should expose structured editorial operations rather than raw SQL or filesystem access.

Possible tools include:

```text
list_documents
search_documents
get_document

create_document
update_document_metadata

list_sections
get_section
insert_section
update_section
move_section
delete_section

create_revision
list_revisions
restore_revision

preview_document
submit_for_review
publish_document
unpublish_document

list_assets
get_asset
upload_asset
```

The exact tool surface should stay relatively small and composable.

---

## 15. AI Editing Semantics

AI edits should preferably target sections rather than replacing entire documents.

For example:

```text
update_section(
    document_id,
    section_id,
    expected_revision,
    data
)
```

The `expected_revision` field enables optimistic concurrency control.

If another editor modifies the document before the AI submits its change, the operation should fail with a revision conflict rather than silently overwrite newer content.

This is particularly important for simultaneous human and AI editing.

---

## 16. Publishing Workflow

A basic editorial lifecycle may be:

```text
draft
  │
  ▼
review
  │
  ▼
published
```

Publishing should be treated as an application command rather than a simple database field update.

For example:

```text
publish(document)
    │
    ├── validate publication requirements
    ├── verify permissions
    ├── create revision
    ├── change publication state
    ├── invalidate affected caches
    └── return publication result
```

The same operation is used by:

```text
web UI
MCP
future API
CLI
```

---

## 17. Public Site and Editorial System Separation

Although implemented by the same application, public and editorial functionality should remain logically separated.

Example route namespaces:

```text
/                         public site
/articles/:slug           public document

/admin/...                 editorial UI

/mcp                       MCP endpoint

/api/...                   internal or future API
```

Public routes must never expose draft content without explicit authorization.

---

## 18. Configuration

Verso should be configurable through a file such as:

```text
verso.toml
```

Example:

```toml
[site]
name = "Example Publication"
base_url = "https://example.org"
language = "en"

[server]
host = "127.0.0.1"
port = 8080

[database]
path = "./data/verso.db"

[storage]
type = "filesystem"
path = "./data/assets"

[cache]
path = "./data/cache"

[ui]
theme = "default"
logo = "/assets/logo.svg"

[features]
math = true
interactive_sections = true

[mcp]
enabled = true
allow_publish = false
```

Configuration syntax and available options may evolve, but deployment-specific concerns should remain outside content data whenever possible.

---

## 19. UI Customization

Verso should separate application behavior from publication presentation.

The public UI may be customized using:

```text
configuration
themes
templates
static assets
CSS variables
```

The first version does not need to support arbitrary theme engines.

A minimal theme contract is preferable to premature generalization.

---

## 20. Internal Layering

A possible high-level implementation structure is:

```text
src/
├── domain/
│   ├── document
│   ├── section
│   ├── revision
│   ├── user
│   └── permissions
│
├── application/
│   ├── documents
│   ├── publishing
│   ├── revisions
│   └── assets
│
├── storage/
│   ├── sqlite
│   └── assets
│
├── render/
│   ├── document
│   ├── markdown
│   ├── templates
│   └── interactive
│
├── cache/
│
├── web/
│   ├── public
│   └── admin
│
├── mcp/
│
├── auth/
│
└── main
```

The exact module layout depends on the implementation language, but dependency direction should remain approximately:

```text
interfaces
    ↓
application
    ↓
domain
```

with infrastructure implementing storage and rendering services required by the application.

---

## 21. Deployment Model

The initial target deployment should remain simple:

```text
Reverse proxy / CDN
        │
        ▼
      Verso
        │
   ┌────┴─────┐
   ▼          ▼
SQLite      assets
```

A production deployment may use:

```text
Cloudflare
Caddy
nginx
Traefik
```

in front of Verso, but the application should not depend on any particular reverse proxy.

The public site should make extensive use of HTTP caching where appropriate.

---

## 22. Non-Goals for the Initial Version

The first version does not need to provide:

* multiple database engines;
* distributed application instances;
* collaborative character-by-character editing;
* arbitrary user code execution in the main page context;
* complex workflow engines;
* plugin marketplaces;
* generic no-code database construction;
* compatibility with every CMS content model;
* full visual page-building.

These can be evaluated later if real requirements emerge.

---

## 23. Initial Technology Direction

The implementation is intentionally experimental.

A possible initial stack is:

```text
Language:          Zig
Database:          SQLite
Public rendering:  server-side HTML
Content text:      Markdown inside text sections
Assets:            filesystem initially
Interactive code:  JavaScript and/or WASM
Caching:           filesystem + HTTP/CDN
AI integration:    remote MCP server
Authentication:    web sessions + OAuth-compatible MCP authorization
```

The architecture should avoid unnecessary abstractions intended solely to support hypothetical future technologies.

SQLite, filesystem storage, and a single application process should be treated as deliberate first-class design decisions rather than temporary placeholders.

---

## 24. Summary

Verso is a small, configurable publishing server centered around structured documents.

Its core architecture is:

```text
                        ┌──────────────┐
                        │   Editors    │
                        └──────┬───────┘
                               │
                ┌──────────────┼──────────────┐
                │                             │
             Web CMS                      AI Client
                │                             │
                │                         MCP + OAuth
                │                             │
                └──────────────┬──────────────┘
                               ▼
                    ┌────────────────────┐
                    │       Verso        │
                    │                    │
                    │ Application layer  │
                    │ Domain model       │
                    │ Renderer           │
                    │ Authorization      │
                    │ Cache manager      │
                    └─────────┬──────────┘
                              │
                    ┌─────────┴─────────┐
                    ▼                   ▼
                 SQLite              Assets
                    │
                    ▼
              canonical content

Public request
      │
      ▼
CDN → page cache → renderer → SQLite
```

The key design goals are:

* simple self-hosting;
* structured and interactive publishing;
* server-rendered public content;
* strong cacheability;
* safe multi-editor workflows;
* first-class AI-assisted editing through MCP;
* portable content;
* minimal infrastructure;
* room for experimentation without unnecessarily generalizing the initial implementation.

