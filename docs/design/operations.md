# Verso — Operations and Boundaries

## Scope

This document defines cross-cutting operational policy: publication commands, public/private route boundaries, deployment configuration, UI customization, failure behavior, initial non-goals, and the canonical/derived/recoverable-local/ephemeral state boundary. It does not define the detailed content schema, renderer internals, or MCP tool catalog.

Related: [system architecture](system.md), [content model](content.md), [rendering and cache](rendering.md), [web editor and preview](editor.md), and [identity and MCP](identity-and-mcp.md).

## 1. Publication Workflow

A basic workflow is:

```mermaid
stateDiagram-v2
    [*] --> Draft
    Draft --> Review
    Review --> Published: initial publication
    Draft --> Published: publish version
    Published --> Archived: replaced by next version
```

Creating a next-version draft does not transition the current published
version; it creates a separate draft version alongside it. The published
version transitions to `archived` only when that next version is published.

The create-next-version operation accepts only the current published version
as its source. It must reject drafts and all other unpublished versions as
parents. A draft's working revisions, local recovery snapshots, and unsaved
preview state do not change this rule.

The state belongs to a numbered document version. Published and archived
versions are immutable, except for the deliberately mutable
`archive_accessible` access-control field. A published document is never edited
in place.
Publication is an application command, not merely changing a status field:

```text
set version.state = "published"
```

Conceptually:

```mermaid
flowchart TB
    edit["Edit published document"] --> copy["Create next-version draft\n(deep copy)"]
    copy --> draft["Draft version N+1"]
    draft --> publish["publish(next_version)"]
    publish --> validate["Validate draft"]
    validate --> permissions["Verify permissions"]
    permissions --> metadata["Verify required metadata"]
    metadata --> concurrency["Check expected version/revision and current parent"]
    concurrency --> revision["Freeze/record publication version"]
    revision --> state["Publish N+1; archive N"]
    state --> transaction["Commit one transaction"]
    transaction --> event["Emit post-commit cache event"]
    event --> invalidate["Invalidate affected cache"]
    invalidate --> result["Return result"]
```

Creating the next version and publishing it are separate operations. The copy
must duplicate all sections and nested objects logically; a physical
copy-on-write representation is allowed only if it preserves independent
version isolation. The publication transaction must fail on stale state and
must leave the previous publication in place if validation, authorization,
concurrency checks, or persistence fails.

The database publication swap is atomic: the new version is published and the
old version is archived together, or neither change is committed. Cache
invalidation is post-commit derived-state work and must be retryable; a cache
failure must not roll back the canonical publication swap.

The archive operation retains the replaced version as a read-only historical
record. Its `archive_accessible` field defaults to true and may be changed by
the author or an authorized manager. Changing archive visibility must not
modify the version's content. Ordinary public routes resolve only the current
published version; a historical route may resolve an archived version only
when it is accessible. Editorial management may inspect inaccessible archives
read-only.

The same publishing service is called from:

* the web editor;
* MCP;
* future APIs.

The service is also responsible for rejecting writes against published or
archived versions. A request to edit one must first use the create-next-version
operation.

---

## 2. Public and Editorial Route Separation

Public and private functionality should remain logically distinct.

Example:

```text
/                         public homepage
/articles/:slug           public article
/articles/:slug/versions/:version
                          public read-only historical version, when accessible
/series/:slug             public series
/subjects/:slug           public subject

/admin/...                 editorial application

/mcp                       MCP endpoint

/auth/...                  authentication/authorization
```

Draft content must never be exposed by ordinary public routes.

---

## 3. Configuration

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

## 4. UI Customization

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

## 5. Failure Principles

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
the new version remains unpublished and the current published version remains
current
```

If archiving or publication persistence fails, the transaction rolls back and
the current publication remains unchanged. If cache invalidation fails after a
successful commit, canonical content remains valid and the affected public and
historical pages can be regenerated or invalidated by retry.

### MCP conflict

If another editor modified a document:

```text
operation returns conflict
```

rather than overwriting the newer version.

---

## 6. Non-Goals for Initial Versions

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

## 7. Design Philosophy

Verso should distinguish clearly between four categories of state.

### Canonical state

```mermaid
flowchart LR
    sqlite[("SQLite")] --> canonical["Canonical publication state"]
    assets["Asset storage"] --> canonical
```

This represents the publication.

---

### Derived state

```mermaid
flowchart LR
    html["Rendered HTML"] --> filesystem["Filesystem cache"] --> cdn["CDN cache"]
    derived["Derived state"] -. regenerable from canonical state .-> html
```

This can always be regenerated.

---

### Recoverable local draft state

```text
browser autosave
IndexedDB or localStorage
local draft snapshot
```

This state is durable enough to recover interrupted editing, but it is not
canonical and is not guaranteed to exist on another browser or device. It may
be restored, merged, or discarded explicitly by the editor.

```mermaid
flowchart LR
    editor["Editor state"] --> autosave["Browser autosave"]
    autosave --> local["IndexedDB / localStorage"]
    local --> recovery["Restore or merge"]
    recovery --> server["Explicit save to Verso"]
```

---

### Ephemeral state

```mermaid
flowchart TB
    ephemeral["Ephemeral state"] --> unsaved["Unsaved editor changes"]
    ephemeral --> preview["Preview requests"]
    ephemeral --> buffers["Temporary rendering buffers"]
    ephemeral --> htmx["Pending HTMX operations"]
```

This should not become canonical accidentally.

The architecture should preserve these boundaries consistently.

---

## 8. Summary

Verso is a self-hosted publishing server built around:

```mermaid
flowchart TB
    editors["Editors"] --> web["Web CMS<br/>HTMX 4"]
    editors --> mcp["AI MCP<br/>OAuth"]
    web --> verso["Verso application"]
    mcp --> verso
    verso --> domain["Domain model"]
    verso --> services["Application services"]
    verso --> renderer["Renderer"]
    verso --> authorization["Authorization"]
    verso --> preview["Preview engine"]
    verso --> cache["Cache manager"]
    domain --> canonical["Canonical state"]
    canonical --> sqlite[("SQLite")]
    canonical --> assets["Assets"]
    verso --> pagecache["Filesystem page cache"]
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
