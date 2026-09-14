# Verso — Implementation Plan

## Purpose and conventions

This is the ordered backlog derived from the [architecture](design.md); it
describes planned, not implemented, work.

`BOOT-001` and `SCHEMA-001` are prerequisites. Every later row is a complete
vertical slice with an observable interface, shared application services, and
focused verification. Its listed architectural divisions are its only
subtasks, with a maximum of four.

`todo` means not implemented; change it to `done` only when the stated outcome
and verification are complete, with a short implementation note or PR
reference. Public rendering comes before authentication because it is
anonymous and read-only; earlier editor work remains browser-local and creates
no unauthenticated server mutation path. Rendering slices construct any needed
published fixtures through application services for integration tests; they do
not introduce a public or unauthenticated publishing interface.

## Prerequisites — bootstrap and schema

These are deliberately not feature slices. They must be complete before
starting `DOC-001`.

| Code | Prerequisite | Required outcome | Status |
| --- | --- | --- | --- |
| `BOOT-001` | Application bootstrap | A Zig executable loads validated `verso.toml`, establishes the `data/` layout, starts a single-process HTTP server, has structured error/log output, and provides the planned `init` and `serve` commands. | todo |
| `SCHEMA-001` | Initial SQLite migration | One versioned initial migration creates the full initial canonical schema, constraints, indexes, migration ledger, and WAL-safe connection setup required by this plan. It distinguishes document/version/section/revision state, identity and grants, assets, cache invalidation work, idempotency results, and audit/provenance data. | todo |

The initial migration is the schema-design checkpoint. A later task may use its
tables but must not quietly introduce a new data model; a genuinely missing
schema decision requires an explicit architecture update and migration task.

## 1. Core document drafts and typed sections

| Code | Vertical-slice outcome | Architectural divisions (up to four) | Status |
| --- | --- | --- | --- |
| `DOC-001` | A local operator can create a new, unlisted text document draft through a narrow bootstrap command that calls the ordinary document application service. The draft has a stable document ID, version 1, metadata, and a text section; invalid types and duplicate mutable drafts are rejected. This temporary bootstrap surface is removed from normal use once protected editorial creation is delivered in `IAM-003`. | domain; application; SQLite storage; CLI | todo |
| `DOC-002` | The same draft supports inserting, editing, moving, duplicating, and deleting text and image section records through application services. Ordering is stable and validation rejects invalid positions, malformed data, or mutations of non-drafts. | domain; application; SQLite storage; CLI | todo |
| `DOC-003` | `create_next_version` deep-copies a current published document's version-owned metadata, sections, and nested objects into exactly one next draft; source versions remain immutable. The service rejects unpublished parents and atomically enforces the one-mutable-version rule. | domain; application; SQLite storage; CLI | todo |
| `DOC-004` | Draft saves create immutable working-revision checkpoints and enforce expected version/revision values; stale writes fail without overwriting data. The slice also supports listing and restoring a checkpoint into the active draft without editing published or archived content. | domain; application; SQLite storage; CLI | todo |
| `DOC-005` | A draft carries validated version metadata, including its immutable logical document type, title, slug, description, subjects, optional series, and series position. Type-to-collection mapping is deployment configuration rather than editable metadata. | domain; application; SQLite storage; CLI | todo |

## 2. Web editor, local preview, and local recovery

This section is intentionally browser-local. It has no endpoint that accepts
unsaved document content and no server mutation path before `IAM-003`.

| Code | Vertical-slice outcome | Architectural divisions (up to four) | Status |
| --- | --- | --- | --- |
| `ED-001` | A browser can compose an unsaved structured document with text and image-section placeholders, including insertion, edit, reorder, duplication, and deletion. The HTMX-oriented shell and minimal JavaScript use the shared client document model. | web/editor; client document model; UI tests | todo |
| `ED-002` | The editor renders unsaved text content in an explicitly provisional local preview pane. Its Markdown subset disables raw HTML, escapes output, validates URLs, and prevents stale asynchronous work from replacing a newer render. | web/editor; client renderer; security tests | todo |
| `ED-003` | Browser-local recovery stores namespaced structured snapshots in IndexedDB (with a limited fallback), restores only after an explicit user choice, and reports storage failures without blocking editing. Snapshots are isolated by site and owner scope and are never transmitted as preview data. | web/editor; browser storage; UI/security tests | todo |

## 3. Safe server rendering and public routes

| Code | Vertical-slice outcome | Architectural divisions (up to four) | Status |
| --- | --- | --- | --- |
| `RND-001` | A current published text document is rendered on the server using the specified restricted Markdown profile, fixed HTML construction, safe-link policy, and restrictive public CSP. The integration fixture is created through the application service, while XSS and unsafe URL cases are rejected or rendered inert. | render; application/query; web/public; security tests | todo |
| `RND-002` | Public document lookup resolves the type-derived collection, stable document ID, and current slug. It serves the canonical route and redirects stale-slug and ID-only routes without exposing drafts or archives. | domain/query; application; web/public; integration tests | todo |
| `RND-003` | Public document pages use disposable filesystem HTML cache entries written by atomic replacement. Verso resolves current visibility and canonical routing before using the internal cache; cache failure is a renderable miss, never a canonical-data failure. | render; cache/filesystem; web/public; integration tests | todo |
| `RND-004` | Historical routes render accessible archived versions read-only, while hidden, draft, and unknown documents have indistinguishable public not-found behavior. All nonfinal document-derived responses require client revalidation. | application/query; render; web/public; security tests | todo |
| `RND-005` | Public series, subject, and author indexes list only current published documents. Series pages use the configured `/series/:slug` route and ordered unique positions; index cache keys and response headers follow the same revalidation policy as other document-derived pages. | application/query; render; web/public; integration tests | todo |

## 4. Identity, authorization, and protected editorial access

| Code | Vertical-slice outcome | Architectural divisions (up to four) | Status |
| --- | --- | --- | --- |
| `IAM-001` | The deployment can establish an initial owner and use secure web sessions. Login/logout, secure cookie attributes, CSRF protection for unsafe requests, origin handling, and proxy-header trust rules are verified end to end. | auth; application; web/admin; security tests | todo |
| `IAM-002` | Managers can maintain attribution authors and make scoped editor-on-behalf-of-author or editor-on-document assignments. Capability checks are centralized in application services, and audit records capture both the actor and acted-for author. | domain; application; SQLite storage; web/admin | todo |
| `IAM-003` | An authorized editor can create, open, and save an assigned draft in the web editor; unauthorized and stale requests fail safely. Local recovery can explicitly reconcile with the persisted draft, while published and archived versions remain read-only. | auth; application; web/admin; editor integration tests | todo |
| `IAM-004` | An authorized editor can request a non-shareable server preview of a persisted draft. It follows the production renderer and asset-resolution path, has `private, no-store` caching, limits rendering work, and never changes the draft. | auth; application; render; web/admin | todo |

## 5. Publishing, history, finalization, and cache invalidation

| Code | Vertical-slice outcome | Architectural divisions (up to four) | Status |
| --- | --- | --- | --- |
| `PUB-001` | Authorized publication validates a draft and atomically makes it the current published version (or publishes version 1). When replacing a publication it archives the previous version, checks the expected parent/revision, and leaves canonical state unchanged on failure. | domain; application; SQLite storage; web/admin | todo |
| `PUB-002` | Drafts can move through review and return-for-changes; authorized users can inspect revisions and manage archive visibility. Publication validates unique current-published series positions and refreshes series, subject, and author indexes. Archive visibility changes are access-control mutations only and generate the same indistinguishable public not-found behavior as `RND-004`. | domain; application; web/admin; integration tests | todo |
| `PUB-003` | Publication and archive-visibility transactions create durable, idempotent SQLite invalidation work. A post-commit worker invalidates only affected filesystem entries, retries across restart, and never rolls back a committed canonical mutation because cache cleanup fails. | application; SQLite storage; cache/filesystem; worker tests | todo |
| `PUB-004` | A manager can irrevocably finalize an eligible document. Finalization locks all lineage mutations and visibility, invalidates previously validated routes, and allows only the document's fixed pages and version-scoped assets to use immutable browser caching; mutable indexes remain revalidated. | domain; application; cache/filesystem; web/admin | todo |

## 6. Asset storage, upload, and protected delivery

| Code | Vertical-slice outcome | Architectural divisions (up to four) | Status |
| --- | --- | --- | --- |
| `AST-001` | Authorized editors upload configured safe asset types through an application service. The server validates bytes and size, determines content type, computes a checksum, stores content-addressed files outside a static root, and records only durable metadata. | application; filesystem storage; web/admin; security tests | todo |
| `AST-002` | Image sections in a persisted draft can reference authorized uploaded assets and render in the authenticated server preview. Draft-only assets cannot be obtained through public routes. | application; filesystem storage; render; web/admin | todo |
| `AST-003` | A document-owned asset is delivered only through its version-scoped application route after version visibility is checked. It has safe content-disposition and `nosniff` behavior, correct ETags, and revalidation headers except for finalized lineage assets. | application; filesystem storage; web/public; security tests | todo |
| `AST-004` | Asset reference lifecycle and startup/maintenance reconciliation reclaim only unreferenced files that are safe to remove, while retaining shared referenced content. Cache and asset-store failure paths preserve canonical references. | application; filesystem storage; maintenance; integration tests | todo |

## 7. Remote MCP and OAuth

| Code | Vertical-slice outcome | Architectural divisions (up to four) | Status |
| --- | --- | --- | --- |
| `MCP-001` | A registered remote MCP client completes OAuth authorization-code flow with PKCE S256 and exact redirect URIs. Short-lived access tokens are validated and scope-limited; refresh/revocation behavior is safe when refresh is enabled. | auth/OAuth; application; MCP; security tests | todo |
| `MCP-002` | An MCP client with read/write scope can list, search, fetch, create, and edit only documents within its application permissions. Tools call the same application services as the web editor and return actionable validation/conflict errors. | MCP; application; auth; integration tests | todo |
| `MCP-003` | MCP exposes semantic section, revision, next-version, persisted-preview, review, publication, finalization, archive-visibility, and asset operations with expected revision/idempotency requirements. Unpublish, scheduling, and unsaved server previews are absent. | MCP; application; auth; integration tests | todo |

## 8. Document exchange archives

| Code | Vertical-slice outcome | Architectural divisions (up to four) | Status |
| --- | --- | --- | --- |
| `XCH-001` | An authorized user can export a current published version or selected persisted draft as a deterministic document-only ZIP containing manifest, portable metadata, ordered Markdown/front matter sections, and all required asset bytes. | application; archive codec; filesystem storage; MCP/web interface | todo |
| `XCH-002` | An untrusted document-only archive can create a new local draft after complete validation. The importer enforces ZIP/path/size/checksum/YAML/safe-type limits, stages bytes safely, assigns local identities, and leaves no canonical references on failure. | application; archive codec; filesystem storage; security tests | todo |
| `XCH-003` | An authorized user can replace an existing mutable draft from a validated archive or create a next draft only from the target's current publication. Expected revision checks prevent overwrite; imports never publish, fork unpublished drafts, install presentation bundles, or execute content. | application; archive codec; auth; integration tests | todo |

## 9. Operations and maintenance

| Code | Vertical-slice outcome | Architectural divisions (up to four) | Status |
| --- | --- | --- | --- |
| `OPS-001` | Operators receive validated configuration, a production-safe data-directory permission check, feature gates that keep interactive modules disabled, health/readiness diagnostics, and clear startup recovery for cache and staging state. | configuration; application bootstrap; maintenance; integration tests | todo |
| `OPS-002` | An operator can create and restore a coordinated canonical backup containing a consistent SQLite snapshot (including WAL state) and all referenced assets. Restore verification checks schema, checksums, and references in isolation before use. | SQLite storage; filesystem storage; maintenance; recovery tests | todo |
| `OPS-003` | Documented operational procedures cover TLS-proxy configuration, secret handling, cache removal/regeneration, backup/restore testing, and incident-safe failure behavior. The documentation names only commands and behaviors implemented by completed tasks. | operations docs; deployment checks; recovery validation | todo |

## Deferred work

These intentionally have no task code in the initial plan: S3-compatible
storage, interactive-module review/execution, raw HTML capability, CDN or
reverse-proxy response caching, schedule/unpublish workflows, cache inactivity
eviction, multi-document archives, local stdio MCP, and abandoned-draft
preservation or rebase/merge. They require a later architecture decision before
entering this backlog.
