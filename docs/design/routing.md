# Verso — Routing and Static Delivery

## Scope

This document defines HTTP route patterns, route matching, routing-layer
composition, and static response handlers. It does not define authentication,
authorization, document lookup, canonical public URLs, or publication policy.
Those concerns remain owned by the application and identity specifications.

Related: [system architecture](system.md), [operations and boundaries](operations.md),
[web editor and preview](editor.md), and [identity and MCP](identity-and-mcp.md).

## 1. Routing Boundary

Routing is an interface-layer concern. A router selects a handler; it must not
load SQLite records, perform document authorization, or decide whether a draft
is publicly visible.

Every route handler uses the same composition shape as other web layers:

```zig
handle(request: *RequestContext, next: Next) !void
```

A matched route invokes its handler with the current `next` value. A routing
layer that has no matching method and path calls `next` unchanged. This applies
to both unknown paths and method mismatches. A 405 response, if needed, is a
separate later layer or handler policy, not an implicit router side effect.

This preserves ordinary pipeline composition:

```text
request logging
    -> authentication
        -> admin routing layer
    -> public routing layer
    -> static fallback or not-found layer
```

Routing layers may be mounted in an explicit order. Layer order is the
precedence between routing domains. A layer must not consume a request merely
because its path prefix looks familiar; it consumes only an actual route
match.

Public and editorial route layers remain logically separate. A public layer
must never become a fallback for an authorized draft route, and an editorial
layer must not expose draft content through a public match.

An authentication or authorization boundary may wrap a routing layer. Once
that boundary claims a protected namespace, an unauthorized or malformed
request must terminate at that boundary or delegate only to explicitly nested
protected routes. It must not fall through into an unrelated public or static
layer. Generic routing fallthrough is safe only before a security boundary has
claimed the request namespace.

## 2. Comptime Route Patterns

Route declarations should use a small pattern language inspired by Go's
`net/http.ServeMux`, while remaining an ordinary Zig comptime value. The
initial grammar is:

```text
METHOD /literal/path
METHOD /path/{name}
METHOD /path/{rest...}
```

Examples:

```text
GET /admin/editor
GET /articles/{document_id}/{slug}
GET /articles/{document_id}/versions/{version}
GET /assets/{path...}       # future-only generic static route
```

The initial semantics are:

- literal segments match exactly;
- `{name}` matches exactly one non-empty path segment;
- `{name...}` is reserved for a trailing wildcard that matches the remaining
  path below its prefix;
- parameter names are unique within one pattern;
- a trailing wildcard is the only wildcard allowed to consume multiple
  segments;
- trailing-slash behavior is explicit rather than silently redirected;
- query strings are not part of route matching;
- unsupported methods produce no match and fall through to `next`.

The first matcher may support literal paths and single-segment parameters
before trailing wildcards. The generic `/assets/{path...}` example is
future-only and is not the document-owned asset route. A trailing wildcard must not be enabled for
security-sensitive routes until percent-decoding, encoded separators,
malformed-target handling, and normalization rules have been specified. Its
zero-segment behavior must also be explicit before it is implemented.

Patterns are parsed and validated at comptime. Invalid method syntax, malformed
segments, duplicate parameters, misplaced wildcards, and invalid trailing
wildcards should be compile errors attached to the route declaration. The
server should not parse route pattern strings or allocate a route matcher at
startup.

The comptime result may be a compact matcher tree or another generated route
representation. The representation is an implementation detail; declarations
must remain readable and route errors must remain attributable to their source
pattern.

## 3. Matching and Precedence

Within one routing layer, a request is matched by method and path. The matcher
uses deterministic specificity ordering:

1. more literal segments before fewer literal segments;
2. a single-segment wildcard after a literal match;
3. a trailing wildcard after a single-segment wildcard;
4. longer otherwise-equivalent patterns before shorter patterns.

Two patterns with the same method and equal specificity are a declaration
error. The initial implementation should reject ambiguous route tables at
comptime rather than make declaration order accidentally determine behavior.

The request target is reduced to its path before matching. Query values remain
available to application code through the normal request target/query API, but
they cannot select a different route.

Successful captures are request-local ephemeral state. A matched handler may
read named parameters through the request context or a route context passed by
the routing layer. Captures must not be stored in global state or reused across
requests.

Percent-decoding, encoded separators, malformed targets, and normalization
rules must be specified before wildcard routes are used for security-sensitive
paths. Until then, route declarations should prefer literal paths and
application-level validation must not assume that a URL path has already been
canonicalized. The `:slug` and `<document-id>` forms used in other architecture
examples are descriptive URL placeholders; route declarations use `{name}`.

## 4. Routing Layers

A routing layer owns one route table and implements the shared `Layer` API. A
minimal conceptual declaration is:

```zig
const admin_routes = web.routes(.{
    .{ "GET /admin/editor", editor_page },
    .{ "GET /admin/editor.css", editor_stylesheet },
    .{ "GET /admin/editor.js", editor_javascript },
});
```

The exact builder syntax is an implementation decision, but the resulting
value must be usable anywhere a normal `Layer` is accepted. A route handler can
terminate the request or delegate to `next`; the router must not introduce a
second handler protocol.

Separate route layers are useful for distinct concerns:

- authenticated admin routes;
- public document and index routes;
- authentication routes;
- MCP routes;
- embedded application assets;
- a final not-found response.

Mounting, authentication, and authorization may wrap a route layer, but route
matching itself does not grant permission. An authenticated admin layer must
fail or delegate according to its authorization policy before any draft data is
loaded.

## 5. Static Handlers

Static responses are handlers, not special cases in the router. The initial
static handler forms are:

### Embedded static content

`EmbeddedStatic` serves a compile-time byte slice with an explicit content type
and response policy. It is appropriate for:

- the bundled Svelte editor JavaScript;
- the bundled editor stylesheet;
- built-in HTML shells;
- other binary or text assets shipped inside the executable.

The handler does not inspect filesystem paths, access SQLite, or resolve a
request-relative filename. It only writes its configured bytes after the route
layer has selected it.

### Filesystem static content

`FilesystemStatic` serves files below one explicitly configured **public static
root**. This root is a future explicit deployment setting and is distinct from
the canonical filesystem asset store in `storage.filesystem.path`. It is not
currently configured or served. The asset store must never be mounted as a
public static directory; document-owned assets continue to use the
authorization-aware, version-scoped asset handler defined by the content model.
`FilesystemStatic` must enforce:

- traversal-safe path resolution;
- rejection of paths outside the configured root;
- deliberate symlink behavior;
- content-type selection;
- bounded file and response handling;
- separation from SQLite, canonical assets, migration, cache, staging, backup,
  and secret paths.

Filesystem static delivery must not become a general file browser. Public
static files are public only because an explicit public-static route selected
them. Document-owned asset visibility still comes from application route and
document-version checks; a filesystem path alone is not publication
authorization.

Both forms use the shared layer composition API. Cache headers, ETags, and
`HEAD` behavior are explicit handler policy rather than hidden router behavior.
Editor bundles initially remain `no-store` until their asset versioning and
deployment cache policy are specified.

## 6. Initial Boundaries and Non-Goals

The first routing implementation does not need:

- regular expressions or arbitrary pattern expressions;
- runtime route registration;
- host-based routing;
- automatic trailing-slash redirects;
- implicit 405 generation;
- filesystem serving outside a separately configured public static root;
- route-level authorization decisions;
- a separate SPA navigation framework.

The route compiler and matcher should remain small enough to keep the web
interface layer understandable. New pattern features require a concrete route
need and corresponding ambiguity, security, and integration tests.
