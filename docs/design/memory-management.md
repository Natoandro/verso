# Verso — Request Memory Management

## Scope

Verso uses one arena allocator for each HTTP request. The arena is attached to
the `RequestContext`, is available through `request.allocator()`, and is
destroyed exactly once after the request pipeline returns. This policy keeps
request-lifetime data together and gives a later request-memory limit one clear
enforcement point.

This document defines allocation ownership and lifetime. It does not define
SQLite transaction memory, process-wide caches, or the memory policy for
background workers that do not handle an HTTP request.

## 1. Ownership boundaries

There are three relevant allocator lifetimes:

| Lifetime | Owner | Examples |
| --- | --- | --- |
| Process/server | `ServerContext.allocator` | configuration, logger, database and application services |
| Connection/transport | the connection handler | HTTP reader and writer buffers needed before a request context exists |
| Request | `RequestContext.arena` | request metadata, route captures, form bodies, view models, rendered response bodies, and request-scoped service results |

The server allocator must not be used for data that is created only to serve
one request. Conversely, request data must not be retained in a server-owned
service, cache, or canonical record. Values passed to application services are
borrowed for the operation unless the service explicitly copies them into
canonical storage or another independently owned result.

Small fixed-size local values used only synchronously—such as a route-matching
scratch struct—are not allocator-backed ownership and may remain stack-
resident. They must not be returned, stored in the `RequestContext`, or used
to evade a future request-memory limit for variable-sized data.

## 2. Request lifecycle

The HTTP connection handler creates the request context after receiving the
request head:

```text
receive request head
        |
        v
create RequestContext + ArenaAllocator(server allocator)
        |
        v
cache request metadata and run layers/handlers
        |
        v
RequestContext.deinit() -> arena.deinit()
```

`RequestContext.init` allocates its request metadata through the new arena,
including the owned request target, cached header records, and remote address.
Route capture frames and decoded capture values are also request-arena-owned
and are released with the request. `RequestContext.deinit` does not free
individual request objects; it releases the arena once, including on handler
failure.

Request-scoped values must not escape after `deinit`. A handler may pass them
down to application/domain services, render them into the response, or use
them for one operation, but it must not store their slices in server-owned
state.

## 3. Allocation rules

Interface and rendering code obtains the allocator from the request:

```zig
const allocator = request.allocator();
const body = try allocator.alloc(u8, body_size);
```

The initial implementation follows these rules:

1. Form readers and decoded form bodies use the request allocator.
2. Route capture frames, decoded capture values, and cached header records and
   values belong to the request arena.
3. HTML, Markdown preview, template, static-file, error, and other response
   buffers use the request allocator.
4. Application service operations that create request-visible results or
   temporary encoded document data accept the request allocator explicitly.
5. `deinit` methods on request-owned wrappers may remain for API symmetry and
   standalone tests; freeing through an arena allocator is a no-op, and the
   arena remains the authority for reclamation.
6. The request arena must not be used for data that outlives the request,
   including canonical SQLite state, persistent asset bytes, cache entries, or
   server-owned service state.

The arena is a lifetime mechanism, not permission to skip input limits.
Existing body and static-file bounds remain required, and application/domain
validation remains responsible for semantic limits.

## 4. Failure and future limits

Allocation failure is a request failure. The handler must not leave partial
request state in canonical storage, and `deinit` must still run when the
pipeline returns an error. Canonical mutations remain governed by the
application service's validation, authorization, transaction, and optimistic
concurrency rules.

The current arena is backed directly by `ServerContext.allocator` and has no
per-request byte ceiling. A future limit can be introduced by wrapping that
parent allocator with a counting or bounded allocator before constructing the
arena. The wrapper should account for all variable-sized request allocations,
return `error.OutOfMemory` (or a request-specific mapped response) when the
limit is exceeded, and preserve the same `RequestContext.allocator()` API so
handlers do not grow separate accounting paths.

That future change must also decide whether connection buffers are included
in the limit. They are currently connection-owned because they are allocated
before `RequestContext` exists; moving them into the request budget is a
separate lifecycle change.
