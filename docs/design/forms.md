# Verso — Typed Web Form Extraction

## Scope

This document defines the interface-layer contract for extracting
`application/x-www-form-urlencoded` request bodies. It does not define
authentication, authorization, application mutations, or domain validation.
Those concerns remain owned by the existing request pipeline and application
services.

The typed extractor described here is implemented by `src/web/form.zig`.
Configurable strict unknown-field handling remains planned follow-up work in
`WEB-006`.

## 1. Why the generic field bag is insufficient

The previous parser had one `Values` struct containing every field name used by
any endpoint. Every field was optional because the parser did not know which
endpoint was consuming the body. Handlers therefore had to reconstruct each
endpoint's schema with calls such as `required("title")`, followed by separate
integer parsing and ad hoc error handling.

That arrangement has several costs:

- the accepted payload is not visible at the endpoint declaration;
- required fields are represented as nullable values until handler code checks
  them;
- a field can be referenced by a string and misspellings are discovered only
  through the helper's comptime field check;
- text parsing, integer parsing, and presence validation are spread across
  handlers;
- the shared struct grows whenever an unrelated endpoint gains a field.

The parser still needs a generic result for request-body ownership and cleanup,
but it should not own a generic list of application fields. The endpoint should
provide the schema.

## 2. Endpoint-owned schemas

Each distinct form payload should be represented by a small struct near the
handler that consumes it. Required fields use non-optional types; optional
fields use `?T`.

The intended shape is:

```zig
const LoginForm = struct {
    login: []const u8,
    password: []const u8,
};

var parsed = try form.extract(LoginForm, request);
defer parsed.deinit(request.allocator());

const credentials = request.server.identity_service.startLocalSession(
    parsed.value.login,
    parsed.value.password,
    request.remote_address,
);
```

An optional field remains explicit:

```zig
const SaveDocumentForm = struct {
    csrf_token: ?[]const u8,
    document_id: i64,
    version_id: i64,
    expected_revision: u64,
    title: []const u8,
    slug: []const u8,
    description: ?[]const u8,
};
```

`form.extract` returns `form.Extracted(Schema)`. The returned wrapper owns the
request body while `value` has the endpoint's concrete type. The user schema
does not need a hidden allocator or a `body` field.

Schemas are defined per distinct semantic payload rather than by combining
every field used below one route namespace. The completed migration covers
login, password, recovery, author-management, assignment, document, and
section forms. A schema may be reused only when the endpoint contracts are
genuinely identical.

## 3. Comptime extraction contract

`form.extract` should require a comptime-known struct type and use comptime
reflection over its fields. Field names are the wire names by default. The
extractor should validate the schema at comptime and generate the field
assignment logic rather than maintaining a runtime field table or a chain of
endpoint-specific conditions.

The initial `extract` operation should have a permissive unknown-field policy:
fields not declared by the endpoint schema are ignored, preserving the current
parser behavior. This is separate from schema typing and should not complicate
the first migration. The API should leave room for a policy/options argument,
but the spelling and shape of that argument are not fixed by this document.

The initial supported field types are deliberately small:

- `[]const u8` — required decoded text;
- `?[]const u8` — optional decoded text;
- supported integer types — required decimal integers;
- optional supported integer types — optional decimal integers.

The exact integer set should be limited to types already required by the web
handlers, currently positive IDs and non-negative revision values represented by
`i64` and `u64`. New scalar types require a concrete endpoint need and focused
tests.
Empty text is still a present value. Required text emptiness remains domain or
application validation, while an empty numeric value is an extraction error.

The extractor should:

1. validate the content type and configured body limit;
2. decode form components into the owned body buffer;
3. reject malformed encoding and duplicate declared fields;
4. assign values using reflected field names and declared field types;
5. fail with a missing-field error when a required struct field was absent; and
6. release the owned body when extraction or handler processing finishes.

Unknown-field handling is an independent policy decision. A later strict mode
may reject unknown names so the HTML form and endpoint schema fail together,
either through extraction options or a separately named strict operation. That
mode must not be required before the typed extractor migration is complete.
CSRF tokens are ordinary schema fields when supplied in the body; header-based
CSRF handling remains an authentication concern.

Required-field presence is then expressed by the Zig type system. A handler
reads `parsed.value.title` directly instead of calling `required("title")` or
checking for null. Optional fields retain their explicit absence semantics,
including the distinction between a missing field and a submitted empty value.

## 4. Ownership and failure boundaries

Decoded text values point into the allocated request body. The request arena
owns that allocation and reclaims it at request completion. The extracted
wrapper keeps a cleanup method for standalone parsing and API symmetry; request
handlers may still defer it, but it uses `request.allocator()`. Numeric values
are parsed into the schema and do not borrow the body.

Extraction errors are transport/input errors. They must not call application
services, change canonical state, or bypass authentication and authorization.
Handlers continue to perform origin/session/capability checks at the existing
boundaries and then pass typed values to application services. Domain rules
such as title validity, slug policy, password policy, and section semantics
remain below the web layer. A missing required field is an extraction error and
is handled before endpoint-specific rendering; field-specific editor responses
remain the responsibility of later application validation.

Path captures remain separate request-local values. This first extractor slice
does not combine route parameters, query parameters, headers, cookies, and form
fields into one universal extractor protocol. A broader extractor abstraction
can be considered only after a concrete need demonstrates that the focused form
API is insufficient.

## 5. Migration and verification

The completed migration replaced generic `Values` use in the existing endpoint
handlers with schemas for:

- local login, password change, password recovery, and recovery completion;
- author creation and update;
- assignment creation and revocation;
- draft creation and document saving; and
- section mutation operations.

It removed `Values.required`, endpoint-local field-name parsing helpers, and
the all-fields `Values` declaration while preserving application-service
boundaries.

Tests should cover:

- required and optional reflected fields;
- signed and unsigned integer conversion and invalid values;
- empty-versus-missing values;
- duplicate fields and the initial ignored-unknown-field behavior;
- malformed percent encoding, content types, and body limits;
- cleanup on extraction failure; and
- endpoint migration without direct storage or authorization logic.
