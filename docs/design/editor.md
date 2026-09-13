# Verso — Web Editor and Preview

The HTMX editor, live previews, and stale-response handling.

This document is part of the [Verso architecture index](../design.md).

## 22. Web Editor

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

## 23. Section-Oriented Editor

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

## 24. Live Side Preview

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

## 25. Preview Is Not Save

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

## 26. Partial Preview Rendering

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

## 27. HTMX Preview Requests

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

## 28. Optimistic Preview Behavior

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

## 29. Avoiding Stale Preview Responses

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

## 30. Full-Document Preview

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
