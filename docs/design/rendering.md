# Verso — Rendering and Cache

Public rendering, preview-independent cache behavior, and invalidation.

This document is part of the [Verso architecture index](../design.md).

## 15. Public Rendering

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

## 16. Rendering Pipeline

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

## 17. Published Page Cache

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

## 18. Why the Cache Is Not Stored in SQLite

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

## 19. Cache Writes

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

## 20. Cache Invalidation

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

## 21. Draft Rendering and Caching

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
