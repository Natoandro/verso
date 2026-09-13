# Verso — System Architecture Specification

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
* server-rendered live previews;
* filesystem caching of published pages;
* filesystem or S3-compatible storage for large assets;
* support for interactive JavaScript and WASM modules;
* configurable publication appearance and behavior.

Verso is not tied to any particular publication.

A site such as Bracket is simply one deployment of Verso.

---

# 2. Architectural Goals

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

# 3. High-Level Architecture

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

# 4. Initial Technology Direction

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

# 5. Deployment Model

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

# 6. SQLite

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

# 7. Content Model

## 7.1 Document

The primary publication unit is a `Document`.

An article is one possible document type.

Conceptually:

```text
Document
├── metadata
└── ordered sections
```

Common document metadata may include:

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
updated_by
```

Possible statuses include:

```text
draft
review
scheduled
published
archived
```

Document-type-specific fields may be stored separately or as structured metadata.

An article may additionally contain:

```text
authors
subjects
series
series_position
```

---

# 8. Section-Based Content

Verso does not treat the entire document as one monolithic Markdown body.

Instead:

```text
Document
├── Text section
├── Image section
├── Text section
├── Interactive section
├── Quote section
└── ...
```

A section has a common structure such as:

```text
id
document_id
position
kind
data
```

The `data` field contains type-specific structured content.

---

# 9. Text Sections

Text sections contain Markdown.

For example:

```json
{
  "markdown": "Let $K/\\mathbb{Q}$ be a number field..."
}
```

A text section may contain:

* paragraphs;
* headings;
* lists;
* equations;
* citations;
* footnotes;
* code;
* links;
* inline images where appropriate.

Verso should avoid turning every paragraph or equation into a separate database object.

A text section should remain a reasonably large semantic unit.

---

# 10. Image Sections

An image section references an asset rather than embedding image bytes in SQLite.

Example:

```json
{
  "asset_id": "01K...",
  "alt": "Prime decomposition diagram",
  "caption": "Decomposition of a rational prime",
  "display": "wide"
}
```

The corresponding binary object lives in the configured asset store.

---

# 11. Interactive Sections

Interactive sections should reference controlled, versioned interactive modules.

Example:

```json
{
  "module": "monte-carlo-area",
  "version": 2,
  "config": {
    "samples": 5000,
    "show_grid": true
  }
}
```

The module may consist of:

```text
JavaScript
CSS
WASM
static assets
```

The module is stored as an asset or collection of assets and referenced from SQLite.

---

# 12. Interactive Module Versioning

Interactive modules should be immutable once published.

For example:

```text
monte-carlo-area@1
monte-carlo-area@2
monte-carlo-area@3
```

An existing publication may continue using version 1 even after later versions are introduced.

This prevents changes to an interactive implementation from silently modifying old publications.

---

# 13. Arbitrary Script Execution

Verso should not execute arbitrary editor-provided JavaScript directly in the main publication context.

The preferred model is:

```text
registered/versioned module
+
structured configuration
```

If arbitrary HTML/CSS/JavaScript documents are supported later, they should execute inside a sandboxed iframe with an intentionally restrictive capability model.

---

# 14. Asset Storage

Binary assets are stored separately from SQLite.

The initial implementation should support:

```text
local filesystem
```

The architecture may later support:

```text
S3-compatible object storage
RustFS
```

Typical assets include:

```text
images
PDFs
datasets
downloads
JavaScript bundles
WASM modules
stylesheets
```

SQLite stores asset metadata such as:

```text
id
object key/path
content type
size
checksum
created_at
uploaded_by
```

---

# 15. Public Rendering

Verso renders public pages on the server.

Conceptually:

```text
HTTP request
     │
     ▼
outer/CDN cache
     │ miss
     ▼
filesystem cache
     │ miss
     ▼
load canonical content
     │
     ▼
render sections
     │
     ▼
render document template
     │
     ▼
write filesystem cache
     │
     ▼
response
```

Server rendering is therefore primarily performed when a page is not already cached.

---

# 16. Rendering Pipeline

Rendering should be conceptually pure:

```text
Document
   ↓
Rendered Document
```

Each section type has a renderer:

```text
Text        → Markdown → HTML
Image       → <figure>...
Interactive → module container + loader
Quote       → <blockquote>
Embed       → configured embed representation
```

The rendering engine should not care whether the document was requested by:

* a public page;
* the editor preview;
* MCP;
* a future API;
* internal cache regeneration.

---

# 17. Published Page Cache

Rendered published pages should use filesystem caching.

The filesystem cache is disposable derived state.

Example:

```text
data/cache/
├── index.html
├── articles/
│   └── example.html
├── series/
│   └── number-theory.html
└── subjects/
    └── mathematics.html
```

The entire cache directory should be safely removable:

```bash
rm -rf data/cache/*
```

Verso should regenerate missing entries automatically.

SQLite remains the source of truth.

---

# 18. Why the Cache Is Not Stored in SQLite

Rendered HTML should normally not be stored inside the database.

SQLite contains canonical state.

The filesystem contains regenerable output.

This avoids:

* database growth from derived HTML;
* unnecessary SQLite writes;
* coupling cache lifetime to database backups;
* cache regeneration interfering with canonical transactions.

The filesystem also benefits naturally from the operating system's page cache.

---

# 19. Cache Writes

Cache generation should use atomic replacement.

Conceptually:

```text
article.html.tmp
       │
       │ complete render
       ▼
atomic rename
       │
       ▼
article.html
```

Readers should never observe partially generated pages.

---

# 20. Cache Invalidation

Cache invalidation should be event-driven.

Publishing or updating a published document may invalidate:

```text
/document/:slug
/
series pages
subject pages
author pages
feed
sitemap
related-document indexes
```

Only pages affected by the operation should need invalidation.

The first implementation may use straightforward invalidation rather than sophisticated dependency graphs.

---

# 21. Draft Rendering and Caching

Drafts and mutable editorial views should not use the public filesystem page cache.

A draft request follows approximately:

```text
authenticated editor
       │
       ▼
authorization check
       │
       ▼
load current draft
       │
       ▼
render current state
       │
       ▼
return response
```

Private preview routes should normally use restrictive caching headers such as:

```text
Cache-Control: private, no-store
```

The key rule is:

> Mutable editorial state is not cached as public rendered output.

Immutable historical revisions may later be cached safely if useful.

---

# 22. Web Editor

Verso provides a browser-based editorial interface.

The initial editor uses:

```text
HTML
+
HTMX 4
+
minimal JavaScript
```

A full SPA framework should not be required unless a concrete feature later justifies it.

The editor operates through normal Verso application services.

```text
Browser
   │
   ▼
web handler
   │
   ▼
application service
   │
   ├── authorization
   ├── validation
   ├── revision handling
   ├── persistence
   └── invalidation
   │
   ▼
SQLite
```

---

# 23. Section-Oriented Editor

The editor represents documents as ordered sections.

Example:

```text
┌──────────────────────────────────┐
│ Article title                    │
├──────────────────────────────────┤
│ ≡ Text                           │
│   [Markdown editor............]  │
├──────────────────────────────────┤
│ ≡ Image                          │
│   [diagram.png]                  │
├──────────────────────────────────┤
│ ≡ Interactive                    │
│   Monte Carlo Area               │
├──────────────────────────────────┤
│                                  │
│          + Add section           │
└──────────────────────────────────┘
```

Sections may be:

* inserted;
* edited;
* reordered;
* duplicated;
* removed.

---

# 24. Live Side Preview

The editor should support an optional live preview pane.

Example:

```text
┌────────────────────────────┬────────────────────────────┐
│ Editor                     │ Preview                    │
│                            │                            │
│ Text / sections            │ Production-equivalent     │
│                            │ rendered document          │
│                            │                            │
└────────────────────────────┴────────────────────────────┘
```

The canonical preview should be produced by the Verso server using the same rendering pipeline as publication.

This guarantees:

```text
preview rendering
≈
published rendering
```

---

# 25. Preview Is Not Save

Preview operations should not automatically mutate SQLite.

The editor may send the proposed unsaved state directly to the rendering service.

Conceptually:

```text
browser unsaved state
       │
       ▼
preview request
       │
       ▼
Verso renderer
       │
       ▼
HTML fragment
```

No database write is required.

The following operations remain distinct:

```text
render preview
save draft
publish
```

---

# 26. Partial Preview Rendering

For ordinary text editing, Verso should avoid re-rendering the entire document unnecessarily.

Example:

```text
editing one text section
       │
       ▼
POST preview-section
       │
       ▼
render only section
       │
       ▼
HTMX swaps corresponding preview fragment
```

Possible behavior:

```text
text edit
    → render affected section

image caption change
    → render image section

section reorder
    → render document body

global metadata change
    → render affected page/header region

citation-numbering change
    → full document render if needed
```

This keeps preview operations lightweight.

---

# 27. HTMX Preview Requests

A text section may conceptually use:

```html
<textarea
  hx-post="/admin/preview/section"
  hx-trigger="input changed delay:250ms"
  hx-target="#preview-section-id">
</textarea>
```

The server returns production-equivalent HTML.

A debounce around approximately 150–300 ms is appropriate for text editing.

Exact behavior may be configurable.

---

# 28. Optimistic Preview Behavior

The editor may provide lightweight client-side optimistic updates.

Examples include:

```text
title text
caption text
alt text
visibility
layout selection
editor UI state
```

However, the canonical rendered preview should remain server-generated.

Verso should avoid implementing separate, competing Markdown rendering engines in the browser and server unless necessary.

---

# 29. Avoiding Stale Preview Responses

Rapid typing may result in multiple overlapping preview requests.

Verso must prevent older responses from overwriting newer preview state.

Possible strategies include:

* aborting obsolete requests;
* assigning monotonically increasing preview sequence numbers;
* rejecting or ignoring stale responses.

Conceptually:

```text
request #41
request #42
request #43

only #43 may become current
```

---

# 30. Full-Document Preview

Some features require document context:

* citations;
* footnotes;
* cross-references;
* numbering;
* table of contents;
* section references.

For these cases, the browser may send the full current unsaved document state to a preview endpoint.

Verso constructs an in-memory `Document`, renders it, and returns the result.

This operation still does not imply persistence.

---

# 31. Revisions

Published and editorial content should have recoverable revision history.

Current document state may remain normalized in:

```text
documents
sections
```

while revisions contain immutable document snapshots.

Conceptually:

```text
revision
├── document metadata
└── ordered sections
```

Revision metadata may include:

```text
id
document_id
revision_number
snapshot
created_by
created_at
reason
```

---

# 32. Revision Policy

Revisions may be created:

* on explicit save;
* on submission for review;
* on publication;
* at configurable autosave checkpoints.

Not every keystroke should produce a permanent revision.

---

# 33. Authentication

Verso has one unified user identity model.

The same identity system is used for:

* web editing;
* MCP;
* future APIs.

Possible roles include:

```text
owner
editor
author
contributor
```

Roles are convenience groupings around permissions.

---

# 34. Authorization

The actual authorization model should be capability-oriented.

Possible permissions include:

```text
document:create

document:read:self
document:read:any

document:update:self
document:update:any

document:review
document:publish

asset:read
asset:upload

interactive:create
interactive:publish

user:manage
```

Application services perform authorization.

Interfaces do not implement their own independent security logic.

---

# 35. MCP

MCP is a first-class remote interface for AI-assisted editing.

The initial focus is **online MCP access**.

Local stdio-based editing is outside the initial scope.

Architecture:

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

MCP must never bypass the application service layer.

---

# 36. MCP Authentication

Remote MCP access should use OAuth-compatible authorization.

Typical flow:

```text
AI client
    │
    ▼
Verso MCP endpoint
    │
    ▼
authorization discovery
    │
    ▼
browser/user authentication
    │
    ▼
authorization approval
    │
    ▼
access token
    │
    ▼
authenticated MCP requests
```

The resulting identity maps to an ordinary Verso user.

An AI acts with the authority granted to that user and token.

---

# 37. MCP Scopes

OAuth scopes provide another authorization boundary.

Initial scopes may include:

```text
content:read
content:write
content:review
content:publish

assets:read
assets:write
```

A recommended AI grant may include:

```text
content:read
content:write
```

without:

```text
content:publish
```

This allows AI-assisted drafting without allowing unattended publication.

---

# 38. MCP Tool Design

MCP should expose semantic editorial operations rather than raw database access.

Potential tools include:

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
preview_section

submit_for_review
publish_document
unpublish_document

list_assets
get_asset
upload_asset
```

The tool set should remain small, composable, and domain-oriented.

---

# 39. AI Editing Granularity

AI editing should normally target individual sections.

For example:

```text
update_section(
    document_id,
    section_id,
    expected_revision,
    data
)
```

This is preferable to replacing an entire article when only one section is being edited.

Benefits include:

* fewer accidental modifications;
* lower token usage;
* clearer revision history;
* easier concurrency control;
* better conflict handling.

---

# 40. Optimistic Concurrency

Verso should use optimistic concurrency for editorial mutations.

Example:

```text
current revision = 42

AI submits:
expected_revision = 42
```

If the document has become revision 43 in the meantime, the mutation fails rather than overwriting newer work.

The same mechanism applies to human editors.

---

# 41. Publication Workflow

A basic workflow is:

```text
draft
  │
  ▼
review
  │
  ▼
published
```

Publication is an application command, not merely:

```sql
UPDATE documents SET status = 'published'
```

Conceptually:

```text
publish(document)
      │
      ├── validate document
      ├── verify permissions
      ├── verify required metadata
      ├── create revision
      ├── update publication state
      ├── commit transaction
      ├── invalidate affected cache
      └── return result
```

The same publishing service is called from:

* the web editor;
* MCP;
* future APIs.

---

# 42. Public and Editorial Route Separation

Public and private functionality should remain logically distinct.

Example:

```text
/                         public homepage
/articles/:slug           public article
/series/:slug             public series
/subjects/:slug           public subject

/admin/...                 editorial application

/mcp                       MCP endpoint

/auth/...                  authentication/authorization
```

Draft content must never be exposed by ordinary public routes.

---

# 43. Configuration

Verso should use a deployment configuration file such as:

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

[editor]
preview_debounce_ms = 250

[mcp]
enabled = true
allow_publish = false
```

Secrets should not normally be stored directly inside publicly tracked configuration files.

Environment variables or dedicated secret mechanisms may override sensitive configuration.

---

# 44. UI Customization

Verso should separate publication data from presentation.

Customization may include:

```text
theme
templates
CSS
CSS variables
logo
typography
navigation behavior
homepage structure
document layouts
```

The first implementation should define a small, coherent theme contract rather than a completely generic theme engine.

---

# 45. Internal Layering

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

# 46. Request Paths

## Public request

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

## Draft editor request

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

## Live preview request

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

## MCP edit

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

# 47. Failure Principles

Verso should prefer failure modes that preserve canonical content.

Examples:

### Cache failure

If cache writing fails:

```text
canonical publication remains valid
```

The page can be rendered again.

### Preview failure

If preview rendering fails:

```text
draft remains untouched
```

### Publishing failure

If validation fails:

```text
document remains unpublished
```

### MCP conflict

If another editor modified a document:

```text
operation returns conflict
```

rather than overwriting the newer version.

---

# 48. Non-Goals for Initial Versions

The first versions do not need to provide:

* PostgreSQL;
* MySQL;
* multiple database engines;
* distributed Verso server clusters;
* real-time character-by-character collaborative editing;
* CRDTs;
* arbitrary script execution in the main page;
* visual no-code page building;
* generic relational-data construction;
* third-party plugin marketplaces;
* dozens of publishing workflow states;
* complex workflow engines;
* local MCP editing;
* Git-based storage;
* Git-based publishing;
* mandatory client-side SPA frameworks.

These may be evaluated if actual requirements appear.

---

# 49. Design Philosophy

Verso should distinguish clearly between three categories of state.

## Canonical state

```text
SQLite
+
asset storage
```

This represents the publication.

---

## Derived state

```text
rendered HTML
filesystem cache
CDN cache
```

This can always be regenerated.

---

## Ephemeral state

```text
unsaved editor changes
preview requests
temporary rendering buffers
pending HTMX operations
```

This should not become canonical accidentally.

The architecture should preserve these boundaries consistently.

---

# 50. Summary

Verso is a self-hosted publishing server built around:

```text
                    ┌─────────────────┐
                    │     Editors     │
                    └────────┬────────┘
                             │
                 ┌───────────┴───────────┐
                 │                       │
              Web CMS                 AI MCP
              HTMX 4                  OAuth
                 │                       │
                 └───────────┬───────────┘
                             ▼
                    ┌────────────────┐
                    │     Verso      │
                    │                │
                    │ Domain model   │
                    │ App services   │
                    │ Renderer       │
                    │ Authorization  │
                    │ Preview engine │
                    │ Cache manager  │
                    └───────┬────────┘
                            │
             ┌──────────────┼──────────────┐
             ▼              ▼              ▼
          SQLite          Assets      FS page cache
             │
             ▼
       canonical state
```

The central architectural decisions are:

* **Zig** for the server implementation;
* **SQLite-only** initially;
* **structured documents composed of sections**;
* **Markdown inside text sections**;
* **versioned JS/WASM interactive modules**;
* **server-side rendering**;
* **filesystem caching for published pages**;
* **no public caching of mutable drafts**;
* **HTMX 4 for the web editor**;
* **server-rendered, production-equivalent side previews**;
* **preview, save, and publish as distinct operations**;
* **remote MCP as a first-class AI editing interface**;
* **OAuth and permission-scoped MCP access**;
* **optimistic concurrency for human and AI edits**;
* **one shared application/domain layer for web, MCP, rendering, and publication**.

Verso should remain small enough to self-host easily while providing enough structure to support sophisticated technical and interactive publications.

