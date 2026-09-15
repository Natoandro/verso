# AGENTS.md

## Repository overview

Verso is a design-stage project for a configurable, self-hosted publishing
server. The authoritative architectural reference is
[`docs/design.md`](docs/design.md). The repository may not yet contain an
implementation, build system, or tests; inspect the current tree before
assuming those exist.

## Working principles

- Read `docs/design.md` before making architectural or cross-cutting changes.
- Keep the system simple and self-hostable. Do not introduce infrastructure,
  abstractions, or extension points for hypothetical future requirements.
- Treat SQLite as the initial sole database backend, filesystem assets as the
  initial asset store, and filesystem HTML as disposable derived cache state.
- Keep canonical state, derived state, recoverable local draft state, and
  ephemeral editor/preview state distinct. Cache or preview behavior must not
  be able to corrupt canonical content.
- Route all mutations through application/domain services. Web handlers, MCP,
  and future interfaces must not manipulate SQLite directly or implement
  separate authorization logic.
- Preserve server-side rendering as the publication authority. Client-side
  editor previews may provide immediate feedback and local recovery, but must
  remain compatible with the server renderer and fall back to it when needed.
- Treat preview, save, and publish as separate operations. Previewing unsaved
  state must not persist it.
- Use optimistic concurrency for editorial mutations and fail on stale
  revisions instead of overwriting newer work.
- Keep published interactive modules versioned and immutable. Do not execute
  arbitrary editor-provided JavaScript in the main publication context.
- Keep public routes and authenticated editorial routes logically separate;
  drafts must never leak through ordinary public routes.
- Before binding a C library directly, search for a mature, maintained Zig
  wrapper and evaluate it for compatibility; prefer the wrapper when it meets
  the project requirements. Use direct C translation only when no suitable
  wrapper exists, and document that decision.

## Expected layout

When implementation begins, the design anticipates roughly these boundaries:

```text
src/
├── domain/         entities and permissions
├── application/    use cases and mutations
├── storage/        SQLite and asset-store adapters
├── render/         document, Markdown, and section rendering
├── cache/          filesystem page cache
├── auth/           sessions, OAuth, and authorization
├── web/            public and admin interfaces
├── mcp/            remote MCP interface
└── main.zig       application entry point
```

This is a guide, not a requirement to create every directory immediately.
Maintain the dependency direction:

```text
interfaces → application → domain
                 ↑
             infrastructure
```

## Documentation

Update documentation when behavior or architectural decisions change.

- `README.md` is the project-facing introduction, status, scope, and intended
  deployment overview.
- `docs/design.md` is the architecture index; its linked files in
  `docs/design/` contain the detailed specifications by concern.
- Keep examples clearly labeled as intended/planned until they are actually
  implemented.
- Do not claim that commands, routes, storage backends, or integrations work
  unless they are present and verified in the repository.

## Validation

Before handing off changes:

1. Inspect the diff and confirm that unrelated user changes are preserved.
2. Check Markdown formatting and links.
3. Run the project’s available tests, formatter, or build commands when they
   exist. If none exist, say so explicitly.
4. For rendering or cache changes, verify atomic cache replacement and that
   failure leaves canonical state intact.
5. For mutations, verify authorization, validation, revision/concurrency
   checks, and cache invalidation are handled by the application service.

## Commit workflow

- Before committing, create an independent review subagent to inspect all
  uncommitted changes and propose the commit message. The subagent must not
  edit files or commit.
- Use the review to produce a concise commit message that describes the full
  staged change.
- Always write commit messages in Conventional Commits format, such as
  `feat: add ...` or `fix(config): handle ...`.
- A direct user request such as “commit”, “let's commit”, or “go” after the
  change is sufficient authorization to commit. Do not ask for separate
  confirmation of the commit message; choose it from the reviewed diff and
  report it as part of the handoff. Ask the user only when the commit scope is
  materially ambiguous, includes unrelated changes, or would require a
  destructive operation outside the request.
- Include all intended uncommitted changes after reviewing their scope; do not
  silently omit tracked or untracked files that belong to the change.

## Current repository state

At the time this file was created, the repository contains the architecture
specification in `docs/design.md` and no checked-in implementation tooling.
Re-check the tree rather than relying on this statement after new code lands.
