# Verso — Implementation Plan

## Purpose and conventions

This is the ordered backlog derived from the [architecture](design.md); it
describes planned, not implemented, work.

`BOOT-001`, `BOOT-002`, and `SCHEMA-001` are prerequisites. Every later item is
a complete vertical slice with an observable interface, shared application
services, and focused verification. Its listed architectural divisions are
its only subtasks; keep them focused and normally limit them to four.

`[ ]` means not implemented; change it to `[x]` only when the stated outcome
and every nested division are complete. Public rendering comes before
authentication because it is
anonymous and read-only; editorial mutations remain behind the authenticated
server boundary. Rendering slices construct
any needed published fixtures through application services for integration
tests; they do not introduce a public or unauthenticated publishing
interface.

## Prerequisites — bootstrap and schema

These are deliberately not feature slices. They must be complete before
starting `DOC-001`.

- [x] **BOOT-001 — Application bootstrap**

  Build the initial executable around validated built-in defaults and an
  optional `verso.toml`, automatic preparation of configured runtime
  directories, a single-process HTTP server, structured errors and logs, and
  the planned `config dump-default` and `serve` commands. Verify that startup
  works without a configuration file and rejects invalid configuration when a
  file is present, and that both commands expose the intended behavior.

  - [x] **Configuration contract:** Define the initial `verso.toml` schema for
    runtime, logging format, site, server, database URL, filesystem storage,
    cache, UI, feature, editor, and MCP settings. Development may derive a
    loopback `base_url`; production requires an explicit public URL. Logging
    defaults to pretty output for a development TTY, text for other
    development destinations, and JSON in production, while explicit formats
    remain available. TOML decoding uses the pinned `zig-toml` dependency,
    storage is a tagged union, the UI language is allowlisted to English for
    now, and paths receive traversal-aware validation.
  - [x] **Environment overrides:** Define and implement an explicit,
    allowlisted `VERSO_*` environment-variable mapping. Overrides take
    precedence over the optional `verso.toml` but remain below command-line
    arguments, use strict typed parsing, never expose database URL values in
    errors, and run before production URL and other configuration validation;
    `config.loadFile` provides the file-backed integration point for executable
    startup, while `config.load` accepts assembled `ConfigSources`.
  - [x] **Server runtime and `serve` command:** Build the Zig executable entry
    point that loads validated configuration, opens the configured runtime
    resources, starts a single-process HTTP server, and shuts down cleanly.
    The runtime uses the pinned `vrischmann/zig-sqlite` wrapper for SQLite
    opening, handles SIGINT/SIGTERM shutdown on Linux, keeps the HTTP listener
    single-process, runs connection handlers through `std.Io.Group.concurrent`,
    and emits structured request records to standard error. It also provides
    the initial `ServerContext`/`RequestContext` boundary and a composable
    `Layer`/`Pipeline` API whose handlers can delegate or terminate requests;
    request logging is the first pipeline layer.
  - [x] **Runtime directories and default configuration:** After the `serve`
    runtime exists, implement its startup preparation that recursively creates
    missing parent directories for the configured SQLite database, filesystem
    assets, and derived HTML cache, while failing clearly on unusable paths.
    Add `verso config dump-default` to write the starter TOML configuration to
    standard output without creating or modifying files; leave database
    migration work to `SCHEMA-001`.
  - [x] **Diagnostics and bootstrap verification:** Add structured startup,
    shutdown, and failure output, then verify successful built-in-default and
    file-backed `serve` flows, invalid configuration handling, repeatable
    directory preparation, and permission/path failures.

- [x] **BOOT-002 — Command-line configuration overrides**

  Add an explicit, allowlisted set of command-line options for configuration
  values, including selection of an alternate configuration-file path. CLI
  values are applied after built-in defaults, the optional configuration file,
  and environment overrides, making them the highest-precedence source for
  one-off or container-injected settings. Verify strict typed parsing,
  documented help output, precedence, and safe handling of sensitive values.

  - [x] **CLI contract:** Define stable option names and value syntax for the
    initial configuration fields, the optional config-file selector, and the
    `serve` and `config` command forms.
  - [x] **Configuration loading:** Parse and apply CLI overrides after file and
    environment loading, reject unknown or malformed options, and preserve the
    existing validation and secret-redaction rules.
  - [x] **Diagnostics:** Show effective non-secret configuration sources and
    explain precedence without printing database URLs or other sensitive
    values.
  - [x] **Verification:** Test no-file startup, file-versus-environment-versus
    CLI conflicts, alternate config paths, help output, and invalid CLI input.

- [x] **BOOT-003 — Config-derived `serve` configuration surface**

  Consolidate the `serve` configuration schema so `config.Config` is the sole
  semantic source for field names, nesting, types, defaults, validation, CLI
  value parsing, and environment mappings. Generate the `serve` help text and
  CLI override transport from that type at comptime. Add a sparse metadata
  record type containing only an existing `Config` field path, whether the
  field is exposed as a CLI override, and an optional short description.
  Metadata must be allowed to omit fields, must not define configuration
  values or types, and must fail comptime validation when it names an unknown
  `Config` path. Document generated environment-reference output without
  maintaining a separate environment allowlist. Leave document bootstrap
  command surfaces under DOC-001 and DOC-002.

  - [x] **Schema reflection:** Generate `serve` CLI names, parser types,
    override transport, and ordinary environment names from `config.Config`.
  - [x] **CLI metadata:** Validate sparse exposure/description metadata against
    `Config` without allowing metadata to add configuration fields.
  - [x] **Generated help and references:** Generate `serve --help` and
    operator-facing environment reference output from the reflected schema.

  The current design intentionally keeps `Config` as the semantic source and
  metadata sparse. If future requirements make that metadata exhaustive, a
  later architecture task may evaluate promoting it to a complete
  `ConfigSchema` that generates `Config` and all derived interfaces.

- [x] **SCHEMA-001 — Initial SQLite migration**

  Create one versioned initial migration with the canonical schema,
  constraints, indexes, migration ledger, and WAL-safe connection setup
  required by this plan. Verify that it distinguishes document, version,
  section, and revision state; identities and grants; assets; cache
  invalidation work; idempotency results; and audit/provenance data.

The initial migration is the schema-design checkpoint. A later task may use
its tables but must not quietly introduce a new data model; a genuinely
missing schema decision requires an explicit architecture update and
migration task.

## 1. Core document drafts and typed sections

- [x] **DOC-001 — Create a bootstrap text draft**

  A local operator can create a new, unlisted text document draft through a
  narrow bootstrap command that calls the ordinary document application
  service. The draft has a stable document ID, version 1, metadata, and a
  text section; invalid types and duplicate mutable drafts are rejected. This
  temporary bootstrap surface is removed from normal use once protected
  editorial creation is delivered in `IAM-003`.

  - [x] **Domain:** Define the draft and version invariants, including stable
    document identity, version 1, supported document types, and the one
    mutable-draft rule.
  - [x] **Application:** Provide the create-draft use case with validation and
    authorization boundaries that every interface can call.
  - [x] **SQLite storage:** Persist the document, initial version, metadata,
    and text section atomically while enforcing uniqueness and foreign-key
    constraints.
  - [x] **CLI:** Add the narrow local bootstrap command and verify its success,
    invalid-input failures, and duplicate-draft behavior.

- [x] **DOC-002 — Edit typed draft sections**

  The same draft supports inserting, editing, moving, duplicating, and
  deleting text and image section records through application services.
  Ordering is stable and validation rejects invalid positions, malformed data,
  or mutations of non-drafts.

  - [x] **Domain:** Model text and image sections, ordering, duplication, and
    the rules that prevent edits to published or archived versions.
  - [x] **Application:** Expose section mutation use cases with position,
    payload, draft-state, and expected-revision validation.
  - [x] **SQLite storage:** Store ordered section records and implement
    transaction-safe insert, move, duplicate, update, and delete operations.
  - [x] **CLI:** Provide a small verification surface for section mutations
    and exercise valid operations alongside malformed and non-draft cases.

- [ ] **DOC-003 — Create the next document version**

  `create_next_version` deep-copies a current published document's
  version-owned metadata, sections, and nested objects into exactly one next
  draft; source versions remain immutable. The service rejects unpublished
  parents and atomically enforces the one-mutable-version rule.

  - [ ] **Domain:** Define lineage, current-publication, immutable-source,
    and next-version invariants.
  - [ ] **Application:** Implement the next-version use case and reject
    unpublished parents or an existing mutable version before any partial
    mutation is visible.
  - [ ] **SQLite storage:** Deep-copy all version-owned records in one
    transaction while preserving source immutability and enforcing lineage
    uniqueness.
  - [ ] **CLI:** Add a focused way to create and inspect a next draft, including
    checks for copied nested content and rejected duplicate or invalid forks.

- [ ] **DOC-004 — Save and restore working revisions**

  Draft saves create immutable working-revision checkpoints and enforce
  expected version/revision values; stale writes fail without overwriting
  data. The slice also supports listing and restoring a checkpoint into the
  active draft without editing published or archived content.

  - [ ] **Domain:** Define immutable checkpoint identity, revision ordering,
    active-draft restoration, and stale-write invariants.
  - [ ] **Application:** Implement save, list, and restore use cases with
    optimistic-concurrency checks and safe failure behavior.
  - [ ] **SQLite storage:** Persist immutable revision snapshots and apply
    restores atomically without changing published or archived versions.
  - [ ] **CLI:** Exercise successful checkpoints, stale saves, listing, and
    restoration through a verification command or integration fixture.

- [ ] **DOC-005 — Validate draft metadata**

  A draft carries validated version metadata, including its immutable logical
  document type, title, slug, description, subjects, optional series, and
  series position. Type-to-collection mapping is deployment configuration
  rather than editable metadata.

  - [ ] **Domain:** Define metadata formats, slug and title rules, subject and
    series relationships, and immutable document-type behavior.
  - [ ] **Application:** Provide metadata create/update validation and ensure
    collection mapping is read from deployment configuration.
  - [ ] **SQLite storage:** Persist normalized metadata and relationships with
    the constraints needed for valid series positions and immutable types.
  - [ ] **CLI:** Verify valid metadata changes, rejected malformed values, and
    the inability to edit the logical type or bypass configured collections.

- [x] **DOC-006 — Persist and load complete draft documents**

  The document application layer can save and load a complete mutable draft
  through SQLite without depending on the web editor or IAM. A save persists
  the draft's version metadata and ordered typed sections atomically, checks
  the expected revision, and returns a stale-write failure without partial
  changes. A load round-trips the complete draft aggregate for later editor,
  preview, MCP, and publication use cases. This ticket adds no public route
  and no unauthenticated server mutation path; its verification surface is a
  local application-service or CLI/integration fixture using an explicit
  trusted bootstrap actor. Authorization policy is deliberately wired in by
  `IAM-003` and later interfaces.

  - [x] **Application:** Add the shared draft save/load use cases, keeping
    validation, transaction boundaries, and optimistic-concurrency behavior
    in the application/domain layers without embedding web or IAM concerns.
  - [x] **SQLite storage:** Implement atomic aggregate writes and reads for
    document metadata, the active draft version, and all ordered typed
    sections while preserving foreign-key, uniqueness, and revision
    constraints.
  - [x] **CLI/integration:** Verify create-or-load, complete round-trip,
    repeated saves, stale-save rejection, rollback on failure, and the absence
    of any public or unauthenticated mutation route.

## 2. Web editor and server-rendered preview

The initial editor is online-first and server-transactional. HTMX is the
intended browser interaction layer; the server owns the working draft and
returns HTML fragments after application-service operations. Browser-local
offline editing, local draft recovery, and a separate client-side renderer are
deferred alternatives documented in
[`docs/design/editor-approaches.md`](design/editor-approaches.md).

- [ ] **ED-001 — Render the protected section editor**

  After `IAM-003` exposes the protected editorial boundary, authorized editors
  can list documents under `/admin`, create or open a draft, and edit its
  ordered typed sections through server-rendered HTML and HTMX requests.

  - [ ] **Admin/document UI:** Add the protected document index, create/open
    actions, editor links, loading states, and empty states.
  - [ ] **Section forms:** Render insertion, editing, reordering, duplication,
    deletion, and validation controls as ordinary forms and HTMX fragments.
  - [ ] **Authorization boundary:** Ensure draft content and mutations remain
    behind the authenticated application boundary.

- [ ] **ED-002 — Persist section mutations with concurrency checks**

  HTMX mutations call the shared application services, validate payloads,
  enforce expected revisions, persist atomically, and return the updated
  section or document fragment. Stale requests fail without overwriting newer
  work.

  - [ ] **Persistence transport:** Submit typed section operations with the
    document, version, and expected-revision identities.
  - [ ] **Application integration:** Route every mutation through validation,
    authorization, persistence, and cache invalidation services.
  - [ ] **UI/integration tests:** Verify successful mutations, validation
    failures, stale conflicts, fragment replacement, and public-route
    isolation.

- [ ] **ED-003 — Preview persisted drafts**

  An authorized editor can request a private preview of a persisted draft. The
  preview uses the same server renderer, safe-content rules, templates, and
  asset resolution as publication without entering the public cache or
  changing canonical state.

  - [ ] **Preview endpoint:** Authorize the draft, render through the
    publication-equivalent path, and return private no-store responses.
  - [ ] **Failure behavior:** Keep canonical content unchanged when validation
    or rendering fails.
  - [ ] **Rendering tests:** Verify output parity, authorization, cache
    isolation, safe links, and draft/public route separation.

- [ ] **ED-004 — Defer browser-local editing alternatives**

  Do not add offline editing, browser-local draft recovery, or a separate
  client-side Markdown renderer to the initial implementation. Reconsider only
  when actual editorial use demonstrates that server-transactional HTMX
  editing is insufficient.

## 3. Web routing and static delivery

- [x] **WEB-001 — Compile and validate route patterns**

  Route declarations use a small Go-like method/path pattern language that is
  parsed at comptime. Literal segments and single-segment parameters are the
  initial matcher scope; trailing wildcards are specified and enabled only
  after their path-normalization and security semantics are complete.

  - [x] **Pattern grammar:** Define the initial method, literal-segment,
    `{name}`, and reserved `{name...}` syntax plus malformed-pattern
    diagnostics.
  - [x] **Comptime compiler:** Generate a compact matcher representation,
    reject duplicate parameters and invalid wildcard placement, and reject
    ambiguous equal-specificity declarations.
  - [x] **Request semantics:** Define query exclusion, target normalization,
    percent-decoding, encoded separators, and request-local capture lifetime.
  - [x] **Tests:** Cover valid patterns, compile failures, specificity,
    ambiguity, malformed targets, query strings, and trailing-slash rules.

- [x] **WEB-002 — Compose routing layers**

  Route tables implement the shared
  `Layer.handle(request: *RequestContext, next: Next)` contract.
  Matched handlers receive the same `next` value as ordinary middleware, while
  unknown paths and unsupported methods fall through unchanged. Separate admin,
  public, authentication, MCP, asset, and not-found layers can be ordered
  explicitly without route matching granting authorization.

  - [x] **Router layer:** Build the comptime route-table layer and dispatch
    matched handlers through the existing composition API.
  - [x] **Layer ordering:** Define and verify precedence between mounted routing
    layers, including admin/public separation, security-boundary termination,
    and final not-found handling.
  - [x] **Route context:** Expose named captures as request-local ephemeral
    state without leaking them across requests or treating them as identity.
  - [x] **Integration tests:** Verify matched dispatch, handler delegation,
    path/method fallthrough, precedence, security-boundary isolation, captures,
    and draft-route isolation.

- [x] **WEB-003 — Add static response handlers**

  Static content is served by ordinary handlers selected by routes. Bundled
  editor assets and built-in shells use compile-time embedded bytes; configured
  public static files use a separate public root, while document-owned assets
  remain behind their authorization-aware application handler.

  - [x] **Embedded static:** Implement `EmbeddedStatic` with explicit content
    type, cache policy, response status, and shared layer composition.
  - [x] **Filesystem static:** Define the separate `public_static_root`
    deployment setting and implement `FilesystemStatic` below it without
    exposing canonical assets, databases, migrations, caches, staging, backups,
    or secrets.
  - [x] **HTTP policy:** Define cache headers, ETags, `HEAD`, malformed paths,
    and missing-file behavior without adding hidden router semantics.
  - [x] **Security tests:** Verify traversal, symlink, root-boundary, content
    type, cache-policy, and non-public-asset isolation behavior.

- [x] **WEB-004 — Migrate editor route declarations**

  The editor shell, stylesheet, and bundle routes now use the shared comptime
  route and embedded static-handler APIs. Public, historical, index, auth,
  preview, and MCP features register their own routes in their respective
  feature tickets; this slice does not take ownership of those
  application-specific routes.

  - [x] **Editor integration:** Replace temporary editor route declarations
    with comptime patterns and embedded static handlers.
  - [x] **Composition integration:** Mount the editor layer through the shared
    pipeline while preserving method fallthrough and protected-boundary rules.
  - [x] **Static integration:** Verify embedded HTML, stylesheet, and bundle
    responses use explicit content types and cache policy.
  - [x] **End-to-end verification:** Exercise editor and editor-asset routes,
    unknown paths, method fallthrough, and route isolation.

## 4. Safe server rendering and public routes

- [ ] **RND-001 — Render published text safely**

  A current published text document is rendered on the server using the
  specified restricted Markdown profile, fixed HTML construction, safe-link
  policy, and restrictive public CSP. The integration fixture is created
  through the application service, while XSS and unsafe URL cases are
  rejected or rendered inert.

  - [ ] **Render:** Implement the restricted Markdown-to-HTML pipeline with
    fixed output construction and the safe-link policy.
  - [ ] **Application/query:** Load only the current published version and
    assemble the renderer input through the shared query/service boundary.
  - [ ] **Web/public:** Serve the rendered document with the required public
    CSP and response behavior.
  - [ ] **Security tests:** Verify escaping, inert XSS payloads, unsafe URL
    handling, and fixture creation through application services.

- [ ] **RND-002 — Resolve canonical public document routes**

  Public document lookup resolves the type-derived collection, stable document
  ID, and current slug. It serves the canonical route and redirects stale-slug
  and ID-only routes without exposing drafts or archives.

  - [ ] **Domain/query:** Define canonical identity and slug-resolution rules
    for current published documents.
  - [ ] **Application:** Implement lookup and redirect decisions while keeping
    drafts and archives outside the ordinary public route.
  - [ ] **Web/public:** Add canonical, stale-slug, and ID-only route handling
    with the specified redirect behavior.
  - [ ] **Integration tests:** Verify route resolution, redirects, and the
    absence of draft or archive leakage.

- [ ] **RND-003 — Cache public pages atomically**

  Public document pages use disposable filesystem HTML cache entries written
  by atomic replacement. Verso resolves current visibility and canonical
  routing before using the internal cache; cache failure is a renderable miss,
  never a canonical-data failure.

  - [ ] **Render:** Produce the complete cacheable public HTML response from
    canonical query results.
  - [ ] **Cache/filesystem:** Implement temporary-file writes and atomic
    replacement, with safe behavior when cache reads or writes fail.
  - [ ] **Web/public:** Resolve visibility and canonical routing before cache
    access and render normally on a cache miss.
  - [ ] **Integration tests:** Verify replacement atomicity, miss recovery, and
    that cache failure leaves canonical state intact.

- [ ] **RND-004 — Serve safe historical document routes**

  Historical routes render accessible archived versions read-only, while
  hidden, draft, and unknown documents have indistinguishable public not-found
  behavior. All nonfinal document-derived responses require client
  revalidation.

  - [ ] **Application/query:** Enforce archived-version visibility and the
    indistinguishable not-found policy for hidden, draft, and unknown data.
  - [ ] **Render:** Render historical content read-only with the same safe
    document rules as current content.
  - [ ] **Web/public:** Add historical routes and revalidation headers without
    exposing editorial controls or mutable state.
  - [ ] **Security tests:** Verify access separation, not-found equivalence,
    and cache headers for every nonfinal document-derived response.

- [ ] **RND-005 — Render public indexes**

  Public series, subject, and author indexes list only current published
  documents. Series pages use the configured `/series/:slug` route and ordered
  unique positions; index cache keys and response headers follow the same
  revalidation policy as other document-derived pages.

  - [ ] **Application/query:** Build index queries that select only current
    published documents and enforce unique, ordered series positions.
  - [ ] **Render:** Produce accessible series, subject, and author index pages
    using the shared public rendering rules.
  - [ ] **Web/public:** Expose the configured series route and index responses
    with canonical routing and revalidation headers.
  - [ ] **Integration tests:** Verify filtering, ordering, cache-key isolation,
    and response-header behavior.

## 5. Identity, authorization, and protected editorial access

- [ ] **IAM-000 — Provision the first owner through a single setup boundary**

  A fresh database can be initialized through web registration, the
  `verso auth bootstrap-owner` command, or an optional configuration/environment
  bootstrap record. All three paths call one application service and are
  available only while the `users` table has no rows and no pending bootstrap
  claim exists. The first successful transaction creates the owner role,
  optional local credential, and system audit event; concurrent or later
  attempts are rejected or become an idempotent no-op according to the
  adapter contract, without changing state.

  - [ ] **Domain and configuration contract:** Define the initial-owner input
    shared by all adapters: display name, email, provider subject, local
    login, and Argon2id password hash. Define the empty-database gate,
    already-initialized result, complete-versus-partial configuration rules,
    and the pending/unbound owner state used for OIDC email-only bootstrap.
    Define a singleton `initial_owner_claim` representation and its migration;
    it locks setup without creating an authenticating user. Define OIDC
    identity keys as immutable issuer-plus-subject pairs, not bare subjects.
  - [ ] **Application and SQLite:** Implement one atomic provisioning use
    case with an immediate SQLite write transaction, a second empty-database
    and pending-claim check inside the transaction, owner-role assignment,
    optional local credential storage, audit logging, and safe
    failure/rollback behavior. Add the explicit migration for the singleton
    pending claim and issuer-plus-subject identity constraint. Existing CLI
    bootstrap code must converge on this service rather than retaining a
    parallel storage path.
  - [ ] **Web setup flow:** Make the unauthenticated login boundary redirect
    to a no-user registration page only when no user row or pending claim
    exists. Add origin, CSRF/rate-limit, validation, and session-establishment
    handling for the one-time POST; after initialization, registration must
    redirect to login and must not become public signup.
  - [ ] **CLI/config adapters and OIDC handoff:** Expand the script command
    to accept the shared fields without exposing plaintext passwords in
    argv/logs. Apply a complete config/env record before the listener starts,
    with no ordinary `serve` CLI override. When OIDC is configured, allow
    script/config email-only provisioning only as a pending claim that can be
    activated by a verified callback from the exact configured issuer when the
    normalized email exactly matches the configured target. Verify first-wins
    behavior across all three adapters, claim activation, restart behavior,
    audit records, redaction, and rejection after initialization. Web maps an
    already-initialized result to login, CLI exits non-zero, and configuration
    startup treats it as an idempotent no-op.

  The current local CLI owner bootstrap and web login are partial foundations;
  this slice owns their first-run convergence. OIDC account linking remains
  part of `IAM-001b`, but its verified-email handoff must be specified here so
  email-only bootstrap cannot create an unauthenticated owner.

- [ ] **IAM-001 — Establish secure web sessions**

  After `IAM-000`, the deployment can use secure web sessions for the
  provisioned owner and subsequent users. Login/logout, secure cookie
  attributes, CSRF protection for unsafe requests, origin handling, and
  proxy-header trust rules are verified end to end. First-user creation is
  specified and implemented only by `IAM-000`.

  - [x] **Auth:** Implement the session lifecycle, secure cookie attributes,
    CSRF tokens, origin checks, and explicit forwarded-origin trust rules.
    Proxies never authenticate users or supply identity subjects.
  - [x] **Application:** Centralize session and identity use cases so web
    handlers do not implement their own authentication decisions.
  - [x] **Web/admin boundary:** Mount protected editorial routes, enforce
    origin and CSRF checks, provide secure cookie handling, and fail closed
    while authentication is unavailable or misconfigured.
  - [x] **IAM-001a — Add local password authentication:** Add a native local
    login path for provisioned users that stores only a memory-hard password
    hash, returns generic credential failures, rate-limits repeated failures,
    rotates sessions after login, and provides authenticated password change
    and recovery flows.
  - [ ] **IAM-001b — Add Verso-owned OIDC integration:** Implement the
    authorization-code flow with PKCE inside Verso, including exact redirect
    URI validation, state and nonce checks, issuer and audience validation,
    signed discovery/JWKS verification, explicit account linking, and mapping
    to the shared local user/session service. Do not accept proxy identity
    headers as an alternative implementation.
  - [ ] **Security tests:** Verify the complete native-auth session flow, CSRF
    failures, origin handling, cookie flags, and provider behavior.

  Transport-neutral session and application services are complete. Local web
  login is implemented; OIDC remains deferred, and proxy identity headers are
  not accepted.

- [ ] **IAM-002 — Manage authors and scoped assignments**

  Managers can maintain attribution authors and make scoped assignments for
  editors acting on behalf of an author or working on a document. Capability
  checks are centralized in application services, and audit records capture
  both the actor and acted-for author.

  - [x] **Domain:** Model authors, grants, scopes, capabilities, and the actor
    versus acted-for-author distinction.
  - [x] **Application:** Implement manager-only author and assignment use cases
    with centralized capability checks.
  - [x] **SQLite storage:** Persist authors, scoped grants, and audit records
    with constraints that prevent ambiguous assignments.
  - [x] **Web/admin:** Provide protected management screens and verify denied
    operations do not reveal or mutate unauthorized data.

  The Domain, Application, SQLite, and protected Web/admin management
  divisions are complete. The management screen is served below the admin
  boundary and requires manager capabilities before reading or mutating data.

- [ ] **IAM-003 — Edit assigned drafts in the web editor**

  The backend enforces assignment-scoped authorization for creating, listing,
  opening, and saving drafts through protected application/API boundaries.
  Unauthorized and stale requests fail safely, while published and archived
  versions remain read-only. This ticket adds the IAM and backend boundary
  around the persistence and revision services delivered by the DOC tickets;
  frontend pages and editor wiring belong to `ED-004`.

  - [ ] **Auth:** Enforce editor assignment scope and read-only boundaries for
    published and archived versions.
  - [ ] **Application/API:** Connect protected list, create, open, and save
    operations to the shared draft and revision services with authorization
    and optimistic-concurrency checks; keep handlers free of direct SQLite
    access and duplicate policy logic.
  - [ ] **Backend integration tests:** Verify authorized success, unauthorized
    denial, stale-write safety, read-only published/archive behavior, and that
    public routes cannot resolve drafts.

- [ ] **IAM-004 — Preview a persisted draft privately**

  An authorized editor can request a non-shareable server preview of a
  persisted draft. It follows the production renderer and asset-resolution
  path, has `private, no-store` caching, limits rendering work, and never
  changes the draft.

  - [ ] **Auth:** Restrict preview requests to editors authorized for the
    specific draft and prevent public access to preview routes.
  - [ ] **Application:** Load a persisted draft without saving or publishing
    it, enforce rendering limits, and return a preview-specific result.
  - [ ] **Render:** Reuse the production rendering and asset-resolution rules
    while keeping draft content out of public caches.
  - [ ] **Web/admin:** Expose the protected preview endpoint with
    `private, no-store` headers and verify it cannot mutate the draft.

## 6. Publishing, history, finalization, and cache invalidation

- [ ] **PUB-001 — Publish a validated draft atomically**

  Authorized publication validates a draft and atomically makes it the current
  published version (or publishes version 1). When replacing a publication it
  archives the previous version, checks the expected parent/revision, and
  leaves canonical state unchanged on failure.

  - [ ] **Domain:** Define publication eligibility, current-version, archive,
    and parent/revision invariants.
  - [ ] **Application:** Implement authorized publication as one validated
    mutation with optimistic-concurrency checks.
  - [ ] **SQLite storage:** Commit publication, archival transition, and
    current-version updates atomically, including rollback-safe failure paths.
  - [ ] **Web/admin:** Add the protected publication action and verify stale,
    invalid, and unauthorized requests leave canonical state unchanged.

- [ ] **PUB-002 — Manage review and archive visibility**

  Drafts can move through review and return-for-changes; authorized users can
  inspect revisions and manage archive visibility. Publication validates unique
  current-published series positions and refreshes series, subject, and author
  indexes. Archive visibility changes are access-control mutations only and
  generate the same indistinguishable public not-found behavior as `RND-004`.

  - [ ] **Domain:** Model review states, return-for-changes transitions,
    archive visibility, and series-position uniqueness.
  - [ ] **Application:** Centralize review, revision-inspection, and visibility
    mutations with the relevant capabilities and publication validation.
  - [ ] **Web/admin:** Provide protected review and archive-visibility controls
    and show revision history without exposing mutable internals publicly.
  - [ ] **Integration tests:** Verify authorized transitions, rejected invalid
    transitions, index refreshes, and indistinguishable public not-found behavior.

- [ ] **PUB-003 — Invalidate caches after canonical mutations**

  Publication and archive-visibility transactions create durable, idempotent
  SQLite invalidation work. A post-commit worker invalidates only affected
  filesystem entries, retries across restart, and never rolls back a committed
  canonical mutation because cache cleanup fails.

  - [ ] **Application:** Enqueue invalidation work as part of publication and
    visibility use cases only after affected entries are known.
  - [ ] **SQLite storage:** Persist idempotent invalidation jobs durably with
    retry state and restart-safe claiming.
  - [ ] **Cache/filesystem:** Remove or replace only affected entries and
    tolerate missing or failed cache files without touching canonical data.
  - [ ] **Worker tests:** Verify post-commit processing, retries after restart,
    idempotency, and canonical-state preservation on cleanup failure.

- [ ] **PUB-004 — Finalize an eligible document**

  A manager can irrevocably finalize an eligible document. Finalization locks
  all lineage mutations and visibility, invalidates previously validated
  routes, and allows only the document's fixed pages and version-scoped assets
  to use immutable browser caching; mutable indexes remain revalidated.

  - [ ] **Domain:** Define eligibility, irreversible finalization, lineage
    locking, and immutable-cache invariants.
  - [ ] **Application:** Implement manager-authorized finalization and the
    route/version invalidation decisions it requires.
  - [ ] **Cache/filesystem:** Invalidate old routes and distinguish finalized
    document and asset entries from mutable index entries.
  - [ ] **Web/admin:** Add the protected finalization action and verify that
    later lineage or visibility mutations are rejected.

## 7. Asset storage, upload, and protected delivery

- [ ] **AST-001 — Upload and store safe assets**

  Authorized editors upload configured safe asset types through an application
  service. The server validates bytes and size, determines content type,
  computes a checksum, stores content-addressed files outside a static root,
  and records only durable metadata.

  - [ ] **Application:** Implement authorized upload validation, content-type
    detection, size limits, checksum calculation, and metadata creation.
  - [ ] **Filesystem storage:** Store content-addressed bytes outside the
    static root with safe temporary writes and durable replacement behavior.
  - [ ] **Web/admin:** Add the protected upload interface and return stable
    asset identities without exposing filesystem paths.
  - [ ] **Security tests:** Verify safe-type allowlisting, byte and size
    validation, path isolation, and failure handling.

- [ ] **AST-002 — Reference named version assets from draft content**

  Persisted draft content can reference authorized uploaded assets by a name
  unique within the draft version and render them in the authenticated server
  preview. Draft-only assets cannot be obtained through public routes.

  - [ ] **Application:** Authorize named asset references against the draft and
    maintain the version-to-asset relationship.
  - [ ] **Filesystem storage:** Resolve referenced bytes without exposing the
    storage layout or serving unreferenced draft files.
  - [ ] **Render:** Resolve image assets in the authenticated preview using
    the same safe rendering rules as publication.
  - [ ] **Web/admin:** Add protected reference/edit flows and verify public
    routes cannot retrieve draft-only assets.

- [ ] **AST-003 — Deliver version-scoped public assets**

  A document-owned asset is delivered only through its version-scoped
  application route after version visibility is checked. It has safe
  content-disposition and `nosniff` behavior, correct ETags, and revalidation
  headers except for finalized lineage assets.

  - [ ] **Application:** Authorize asset delivery from the requested document
    version and apply current, archived, hidden, and finalized visibility.
  - [ ] **Filesystem storage:** Read content-addressed bytes safely and return
    checksum metadata needed for validators.
  - [ ] **Web/public:** Implement version-scoped asset routes with safe
    headers, content disposition, ETags, and cache policy.
  - [ ] **Security tests:** Verify route isolation, hidden-version denial,
    `nosniff`, header correctness, and finalized versus mutable caching.

- [ ] **AST-004 — Reconcile asset references and files**

  Asset reference lifecycle and startup/maintenance reconciliation reclaim only
  unreferenced files that are safe to remove, while retaining shared
  referenced content. Cache and asset-store failure paths preserve canonical
  references.

  - [ ] **Application:** Track asset reference lifecycle and define safe
    reclamation eligibility without deleting content still used by a version.
  - [ ] **Filesystem storage:** Reconcile metadata and content-addressed files
    safely during startup and maintenance.
  - [ ] **Maintenance:** Schedule bounded cleanup and recovery work with
    restart-safe behavior.
  - [ ] **Integration tests:** Verify shared-reference retention, unreferenced
    cleanup, and preservation of canonical references on failure.

## 8. Remote MCP and OAuth

- [ ] **MCP-001 — Authenticate remote MCP clients**

  A registered remote MCP client completes OAuth authorization-code flow with
  PKCE S256 and exact redirect URIs. Short-lived access tokens are validated
  and scope-limited; refresh/revocation behavior is safe when refresh is
  enabled.

  - [ ] **Auth/OAuth:** Implement client registration data, authorization-code
    flow, PKCE S256, exact redirect matching, token validation, and revocation.
  - [ ] **Application:** Centralize scope and token lifecycle decisions for MCP
    requests.
  - [ ] **MCP:** Expose the authorization and token endpoints according to the
    remote protocol boundary.
  - [ ] **Security tests:** Verify redirect rejection, PKCE enforcement,
    expiration, scope limits, and safe refresh/revocation behavior.

- [ ] **MCP-002 — Expose permission-scoped document tools**

  An MCP client with read/write scope can list, search, fetch, create, and edit
  only documents within its application permissions. Tools call the same
  application services as the web editor and return actionable
  validation/conflict errors.

  - [ ] **MCP:** Implement list, search, fetch, create, and edit tools with
    stable input and error schemas.
  - [ ] **Application:** Route every tool through shared document services and
    enforce the caller's scopes and assignments.
  - [ ] **Auth:** Apply token scopes and document capabilities consistently to
    every operation.
  - [ ] **Integration tests:** Verify permission boundaries, validation errors,
    stale conflicts, and parity with web editor mutations.

- [ ] **MCP-003 — Expose semantic editorial operations**

  MCP exposes semantic section, revision, next-version, persisted-preview,
  review, publication, finalization, archive-visibility, and asset operations
  with expected revision/idempotency requirements. Unpublish, scheduling, and
  unsaved server previews are absent.

  - [ ] **MCP:** Define and expose the semantic operation set with explicit
    request, response, revision, and idempotency fields.
  - [ ] **Application:** Reuse the corresponding web application services and
    preserve their authorization, validation, and conflict behavior.
  - [ ] **Auth:** Apply operation-specific scopes and assignments, including
    manager-only actions.
  - [ ] **Integration tests:** Verify supported operations, idempotent retries,
    expected-revision failures, and the absence of deferred operations.

## 9. Document exchange archives

- [ ] **XCH-001 — Export deterministic document archives**

  An authorized user can export a current published version or selected
  persisted draft as a deterministic document-only ZIP containing manifest,
  portable metadata, ordered Markdown/front matter sections, and all required
  asset bytes.

  - [ ] **Application:** Authorize export selection and assemble a complete
    immutable document snapshot.
  - [ ] **Archive codec:** Define deterministic ZIP ordering, manifest,
    portable metadata, and ordered Markdown/front matter encoding.
  - [ ] **Filesystem storage:** Read every required asset safely and verify
    that archive references match included bytes.
  - [ ] **MCP/web interface:** Expose protected export through the available
    interfaces with stable download behavior.

- [ ] **XCH-002 — Import untrusted archives as new drafts**

  An untrusted document-only archive can create a new local draft after
  complete validation. The importer enforces ZIP/path/size/checksum/YAML and
  safe-type limits, stages bytes safely, assigns local identities, and leaves no
  canonical references on failure.

  - [ ] **Application:** Validate the complete archive before committing a new
    draft and make failure atomic.
  - [ ] **Archive codec:** Parse and validate ZIP structure, paths, manifest,
    YAML/front matter, checksums, and size limits.
  - [ ] **Filesystem storage:** Stage asset bytes outside canonical storage,
    then commit only validated content with local identities.
  - [ ] **Security tests:** Cover traversal, decompression, malformed data,
    unsafe types, checksum mismatch, and cleanup after failure.

- [ ] **XCH-003 — Replace or fork drafts safely**

  An authorized user can replace an existing mutable draft from a validated
  archive or create a next draft only from the target's current publication.
  Expected revision checks prevent overwrite; imports never publish, fork
  unpublished drafts, install presentation bundles, or execute content.

  - [ ] **Application:** Implement authorized replace and next-draft use cases
    with expected-revision and publication-lineage checks.
  - [ ] **Archive codec:** Reuse complete validation and reject presentation
    bundles or executable content.
  - [ ] **Auth:** Enforce target-draft permissions and manager/editor scope
    boundaries for import mutations.
  - [ ] **Integration tests:** Verify atomic replacement, stale conflicts,
    allowed current-publication forks, and forbidden import behavior.

## 10. Operations and maintenance

- [ ] **OPS-001 — Validate configuration and startup recovery**

  Operators receive validated configuration, a production-safe data-directory
  permission check, feature gates that keep interactive modules disabled,
  health/readiness diagnostics, and clear startup recovery for cache and
  staging state.

  - [ ] **Configuration:** Validate required settings, paths, permissions,
    collection mapping, and safe defaults.
  - [ ] **Application bootstrap:** Integrate startup checks, disabled
    interactive-module gates, and health/readiness reporting.
  - [ ] **Maintenance:** Recover or quarantine stale cache and staging state
    without modifying canonical content unexpectedly.
  - [ ] **Integration tests:** Verify invalid configuration, permission
    failures, diagnostics, feature gates, and recovery behavior.

- [ ] **OPS-002 — Create and restore coordinated backups**

  An operator can create and restore a coordinated canonical backup containing
  a consistent SQLite snapshot (including WAL state) and all referenced assets.
  Restore verification checks schema, checksums, and references in isolation
  before use.

  - [ ] **SQLite storage:** Produce and restore a consistent snapshot that
    includes required WAL state and migration metadata.
  - [ ] **Filesystem storage:** Capture referenced asset bytes and verify their
    checksums during backup and restore.
  - [ ] **Maintenance:** Coordinate backup/restore staging, isolation, and
    promotion without exposing a partially restored canonical state.
  - [ ] **Recovery tests:** Verify schema, checksum, reference, interruption,
    and failed-restore behavior before activation.

- [ ] **OPS-003 — Document implemented operational procedures**

  Documented operational procedures cover TLS-proxy configuration, secret
  handling, cache removal/regeneration, backup/restore testing, and
  incident-safe failure behavior. The documentation names only commands and
  behaviors implemented by completed tasks.

  - [ ] **Operations docs:** Write procedures for deployment, TLS proxying,
    secrets, cache maintenance, and backup/restore using verified behavior.
  - [ ] **Deployment checks:** Validate documented configuration and commands
    against the executable and its production-safe defaults.
  - [ ] **Recovery validation:** Exercise the documented failure and recovery
    procedures, including safe handling of incomplete maintenance work.

## Deferred work

These intentionally have no task code in the initial plan: S3-compatible
storage, interactive-module review/execution, raw HTML capability, CDN or
reverse-proxy response caching, schedule/unpublish workflows, cache inactivity
eviction, multi-document archives, local stdio MCP, and abandoned-draft
preservation or rebase/merge. They require a later architecture decision
before entering this backlog.
