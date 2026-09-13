# Verso — Rendering and Cache

## Scope

This document defines the server transformation from canonical content to public HTML and the lifecycle of derived page output. It owns rendering, filesystem caching, invalidation, atomic writes, and draft-cache boundaries; it does not define editorial UX or persistence schemas. Client-side previews are covered in [web editor and preview](editor.md); the server renderer remains their authority.

Related: [content model](content.md), [system architecture](system.md), [web editor and preview](editor.md), and [operations and boundaries](operations.md).

## 1. Public Rendering

Verso renders public pages on the server.

Conceptually:

```mermaid
flowchart TB
    request["HTTP request"] --> resolve["Resolve document ID and canonical slug"]
    resolve -->|canonical URL / verified cache key| cdn["Outer / CDN cache"]
    resolve -->|stale slug or ID-only URL| redirect["Redirect to canonical URL"]
    cdn -->|miss| cache["Filesystem cache"]
    cache -->|miss| load["Load current published version"]
    load --> render["Render sections"]
    render --> template["Render document template"]
    template --> write["Write filesystem cache"]
    write --> response["Response"]
```

Server rendering is therefore primarily performed when a page is not already cached.

---

## 2. Rendering Pipeline

Rendering should be conceptually pure:

```mermaid
flowchart LR
    document["Document"] --> rendered["Rendered document"]
```

Each section type has a renderer:

```mermaid
flowchart TB
    text["Text"] --> markdown["Markdown"] --> html["HTML"]
    image["Image"] --> figure["Figure element"]
    interactive["Interactive"] --> loader["Module container + loader"]
    quote["Quote"] --> blockquote["Blockquote"]
    embed["Embed"] --> configured["Configured embed representation"]
```

The rendering engine should not care whether the document was requested by:

* a public page;
* the editor preview;
* MCP;
* a future API;
* internal cache regeneration.

The server renderer is authoritative for publication output. The editor may
also use a compatible client-side renderer for immediate previews of local
drafts. Client output is provisional and may be incomplete for features that
require server-side document context.

```mermaid
flowchart LR
    canonical["Canonical document"] --> server["Server production renderer"]
    local["Local draft snapshot"] --> client["Client-side preview renderer"]
    server --> public["Published HTML / authoritative preview"]
    client --> provisional["Provisional local preview"]
```

---

## 3. Published Page Cache

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

## 3.1. Planned Inactivity Eviction

Automatic eviction of cache entries that have not been used for a configured
period is a planned feature, not part of the initial implementation. The
initial cache may grow until an operator removes entries or the cache storage
is otherwise managed externally.

When implemented, eviction should apply only to disposable rendered output.
It may remove inactive current-publication pages and independently cached
historical pages; the next request must regenerate any removed entry from the
canonical version. It must never delete or mutate document versions, sections,
assets, or other canonical state. Cache eviction should also be safe around
concurrent reads and writes, and should tolerate a race by leaving a valid
regenerable cache miss rather than affecting publication.

The inactivity policy, including how access is tracked and whether it is
configurable, can be decided when cache maintenance is implemented. It should
not be confused with archive visibility: hiding an archived version is an
access-control mutation that requires immediate invalidation, whereas
inactivity eviction is best-effort storage maintenance.

---

## 4. Why the Cache Is Not Stored in SQLite

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

## 5. Cache Writes

Cache generation should use atomic replacement.

Conceptually:

```mermaid
flowchart TB
    temporary["article.html.tmp"] -->|complete render| rename["Atomic rename"]
    rename --> page["article.html"]
    readers["Readers"] -. never observe partial output .-> page
```

Readers should never observe partially generated pages.

---

## 6. Cache Invalidation

Cache invalidation should be event-driven.

Publishing a next document version may invalidate:

```text
/<collection>/<document-id>/<current-slug>
old current-slug URL
/<collection>/<document-id> ID-only redirect response
/
series pages
subject pages
author pages
feed
sitemap
related-document indexes
```

Only pages affected by the operation should need invalidation. The ordinary
ID-and-slug route must stop resolving to the archived version and start
resolving to the newly published version after the publication transaction
commits. A request using an outdated slug must redirect to the new canonical
ID-and-slug URL rather than creating a second public identity for the document.
The old-slug page and any ID-only redirect response must therefore be
invalidated in the filesystem cache and any configured outer/CDN cache.

The request path must resolve the document ID and current canonical slug
before serving a URL-keyed page cache entry, unless the cache entry is known to
be keyed by a still-canonical URL. This prevents a stale old-slug page from
bypassing redirect handling. Cache invalidation is still required for already
cached responses at every configured cache layer.

Historical pages for accessible archived versions are immutable derived output
and may be cached independently. If an author hides an archive, its historical
route and any corresponding cache entry must no longer be publicly served. The
visibility mutation must emit an invalidation event, and the request path must
also enforce the access check so a stale cache entry cannot expose the archive.
Authorized editorial inspection remains private and read-only.

The first implementation may use straightforward invalidation rather than sophisticated dependency graphs.

---

## 7. Draft Rendering and Caching

Drafts and mutable editorial views should not use the public filesystem page cache.

A draft request follows approximately:

```mermaid
flowchart TB
    editor["Authenticated editor"] --> authorize["Authorization check"]
    authorize --> draft["Load current draft"]
    draft --> render["Render current state"]
    render --> response["Return response"]
    cache["Public filesystem cache"] -. not used .-> response
```

Private preview routes should normally use restrictive caching headers such as:

```text
Cache-Control: private, no-store
```

The key rule is:

> Mutable editorial state is not cached as public rendered output.

Immutable historical document versions may be cached safely if useful, subject
to their `archive_accessible` setting. Drafts and unsaved previews remain
uncacheable as public output.

---
