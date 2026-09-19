# Verso — Compile-Time Markup Templates

## Scope

This document specifies a small HTML-oriented template engine for
developer-authored Verso application markup. It is used for complete public
pages, authenticated-editorial pages, HTMX fragments, reusable UI components,
layouts, short inline templates, and templates embedded at compile time with
`@embedFile`.

It is not a user template language. Persisted document content remains
untrusted input to the document and Markdown renderers, which must retain the
safety rules in [rendering and cache](rendering.md). Raw template interpolation
is available only to trusted application code and is not a raw-HTML capability
for authors, MCP clients, or imported content.

Related: [system architecture](system.md), [rendering and cache](rendering.md),
and [web editor and preview](editor.md).

## 1. Purpose and Execution Model

The engine combines static markup structure with typed Zig data. It parses and
validates template syntax at compile time, validates context-dependent access
when `render` is instantiated, and streams runtime data directly to a writer.

```text
template source
    ↓
compile-time parsing
    ↓
compile-time template representation
    ↓
compile-time validation against context types
    ↓
runtime rendering directly to a Writer
```

Normal HTTP requests must never parse, tokenize, load, or look up templates.

Debug builds also emit temporary renderer diagnostics to stderr. Each template
entry records the writer address and context type/size; loop and component
entries record the scope address, outer-scope address, and component binding
index. These records are intended to identify the last valid hand-off before a
memory fault, not to replace application logging. They are excluded from
comptime evaluation and release builds. Because requests may render on
different worker threads, diagnostics should be captured together with the
server's stderr and inspected around the failing request.

### 1.1 Renderer stack invariant

The renderer must not require a stack frame proportional to the size of the
template source or the number of static template nodes. The first implementation
uses comptime `inline while` expansion to preserve typed path resolution, which
can turn a large component into a very large generated function and exhaust a
worker thread's stack before its first output operation. This is a renderer
implementation limitation, not a property of the template language.

The planned renderer keeps parsing, AST construction, path resolution, component
validation, and escaping decisions at comptime, but lowers the validated AST to
a compact typed execution plan. Runtime rendering then walks that plan through
small operations and explicit block frames. The plan must not introduce runtime
template parsing, string-based field lookup, untyped dynamic values, or a
component-name registry. Lexical scope storage must remain lifetime-safe; if
runtime frames are allocated in an arena or heap, scope links should use stable
frame references or indexes rather than pointers into movable storage.

## 2. Goals and Non-Goals

The initial engine must:

* parse inline strings and `@embedFile` sources at comptime;
* render normal and anonymous Zig struct contexts at runtime;
* validate fields and supported operations at compile time where the context
  type is known;
* stream directly to a writer;
* escape interpolated strings by default;
* support `if`, `else`, optional capture, `for`, comments, external components,
  lexical local snippets, and layout composition;
* use a deliberately small language with no JSON or dynamic context model.
* keep runtime stack usage bounded independently of template source length.

The initial engine must not provide runtime or user-editable templates,
arbitrary Zig execution, arithmetic, arbitrary calls, variables, assignment,
macros, inheritance, runtime filesystem lookup, or Jinja/Liquid compatibility.

## 3. Template Language

### 3.1 Interpolation and paths

Escaped interpolation uses double braces:

```html
<h1>{{ post.title }}</h1>
```

Paths map to ordinary Zig field access and may traverse structs or supported
pointers to structs:

```html
{{ post.author.name }}
```

Given a context field `post: Post`, `{{ post.titel }}` is a compile error when
`Post` has no `titel` field. The parser splits paths into segments at comptime;
the renderer does not parse expressions.

Triple braces are explicit raw output:

```html
{{{ post.body_html }}}
```

Raw output bypasses escaping and is intended solely for server-generated,
trusted HTML such as section-renderer output. A later safe-HTML type may narrow
or replace this escape hatch.

### 3.2 Escaping and scalar values

Double-brace string output writes escaped bytes directly to the destination
writer, without an allocated temporary. It escapes at least:

```text
&  -> &amp;
<  -> &lt;
>  -> &gt;
"  -> &quot;
'  -> &#39;
```

Supported interpolation values are `[]const u8`, string literals, integers,
floats, booleans, and enums with a defined textual representation. Unsupported
types fail compilation rather than using arbitrary formatting.

### 3.3 Conditionals

`if` supports `bool` and optionals, with an optional `else` branch:

```html
{{#if post.published}}
  <span>Published</span>
{{/if}}

{{#if user}}
  Hello {{ user.name }}
{{#else}}
  Guest
{{/if}}
```

Optional capture mirrors Zig optional capture and exposes the unwrapped value
inside the true branch:

```html
{{#if current_user |user|}}
  Hello {{ user.name }}
{{#else}}
  Guest
{{/if}}
```

Pointers may be admitted as conditions only if the implementation defines
consistent null/non-null semantics; this is not required for the first slice.

### 3.4 Iteration

`for` iterates arrays and slices and captures the element value:

```html
{{#for posts |post|}}
  <article><h2>{{ post.title }}</h2></article>
{{/for}}
```

Nested loops are valid. Iterating any other type is a compile error when
`render` is instantiated.

### 3.5 Comments

Comments produce no output:

```html
{{! This is a template comment }}
```

## 4. Components, Local Snippets, and Composition

Components are parsed templates registered under comptime-known names. A parent
invokes them with a distinct child context:

```zig
const user_card = tmpl.parse(
    \\<article class="user">
    \\  <strong>{{ user.name }}</strong>
    \\</article>
,    .{
        .parameters = .{ .user = {} },
    },
);

const page = tmpl.parse(@embedFile("page.html"), .{
    .components = .{ .user_card = user_card },
});
```

```html
{{> user_card user=user }}
```

Arguments support path references and string, boolean, and integer literals.
External components declare their named child-context parameters in `parse`
options and use named arguments to bind them. A component name, declared and
required argument names, and detectable argument types are validated at
comptime. There is no runtime component-name lookup.

### 4.1 Local snippets

A template may declare a local snippet with explicit, comma-separated
parameters:

```html
{{#snippet post_card |post|}}
  <article id="post-{{ post.id }}">
    <h2>{{ post.title }}</h2>
    <p>{{ post.summary }}</p>
  </article>
{{/snippet}}

{{> post_card post }}
```

A declaration emits no output. A local snippet uses the ordinary invocation
syntax and may bind arguments positionally or by parameter name:

```html
{{#snippet link |href, label|}}
  <a href="{{ href }}">{{ label }}</a>
{{/snippet}}

{{> link post.url post.title }}
{{> link href=post.url label=post.title }}
```

Positional arguments bind in declared parameter order. A call may use named
arguments instead, but must not bind a parameter more than once. A local
snippet body receives only its declared parameters and does not implicitly
capture variables from its enclosing rendering context.

### 4.2 Lexical scope

Snippet declarations are lexical and order-independent within their containing
template or block body. Therefore a call may precede its declaration:

```html
{{> card post }}

{{#snippet card |post|}}
  <article><h2>{{ post.title }}</h2></article>
{{/snippet}}
```

Nested snippets are valid. A nested declaration is visible in its containing
snippet body and its nested scopes, but not outside that body:

```html
{{#snippet article |article|}}
  {{#snippet heading |text|}}
    <h2>{{ text }}</h2>
  {{/snippet}}

  <article>{{> heading article.title }}</article>
{{/snippet}}
```

Invocation resolves the nearest matching local declaration, then enclosing
snippet or template scopes, then the externally registered components. Local
declarations may shadow an outer declaration or external component. This same
rule applies to a declaration inside a loop or other block: its visibility is
limited to that lexical body, regardless of whether the body executes at
runtime.

At runtime, the renderer represents these lexical scopes as a typed borrowed
chain. A scope stores its captured value and a pointer to its outer scope
rather than embedding the entire outer scope by value. This is an important
implementation invariant: rendering is synchronous, so an outer scope pointer
is valid only during the nested render call that created it; scopes must not be
stored after that call returns or used by asynchronous work. The pointer-linked
chain preserves the compile-time type checking above while avoiding large,
repeated stack copies for nested loops, snippets, and component arguments.

### 4.3 Shared fragment representation

External components and local snippets share the same comptime call and binding
rules, but remain different compile-time representations in the initial
engine. Local snippets are AST declaration ranges; external components are
registered template values:

```zig
local declaration -> AST node range
external component -> registered Template value
```

A comptime scope maps local names to declaration indices. Component calls first
resolve a local declaration using lexical scope, then fall back to externally
registered components. Both paths bind arguments at comptime and render through
the ordinary component call path; local snippets introduce no runtime fragment
abstraction or string-based lookup. A unified fragment value remains a future
layout-composition concern rather than a requirement for local snippets.

Layouts use the same mechanism rather than template inheritance. A layout may
receive header, content, and footer component values through a comptime-known
composition API such as:

```zig
const page = layout.with(.{
    .header = header,
    .content = article_page,
    .footer = footer,
});
```

The same `article_page` remains independently renderable for an HTMX fragment.

## 5. Public API

```zig
const tmpl = @import("tmpl");

const template = tmpl.parse(comptime source, .{});
const configured = tmpl.parse(comptime source, comptime options);
const layout = tmpl.layout(comptime layout_source);
const page = layout.with(comptime slots);

try template.render(writer, .{ .post = post, .user = user });
try page.render(writer, .{ .post = post, .user = user });
```

`context` is `anytype`; named and anonymous structs both work. The writer API
is the primitive operation. An optional `renderAlloc(allocator, context)`
convenience method must be implemented by collecting the writer renderer's
output, not by creating a separate render path.

`layout` validates the layout syntax without requiring its component slots.
`with` accepts a comptime-known struct of named slot templates, validates every
layout component call against those slots, and returns an ordinary renderable
template. Slot arguments must explicitly bind the outer context values required
by each composed child.

## 6. Validation and Representation

`parse` reports syntax errors at comptime, including malformed interpolation,
invalid capture syntax, unmatched or unexpected block closers, invalid `else`,
malformed snippet parameters, duplicate snippet names in one scope, and unknown
registered components or locally resolvable snippets.

`render` reports context-dependent errors at comptime when instantiated,
including unknown fields, traversal through unsupported types, invalid
condition or iteration types, missing component arguments, and detectable
component or snippet argument type mismatches. Calls also reject too many
positional arguments, unknown named arguments, duplicate named arguments, and
references to nonexistent snippet or component parameters. Diagnostics should
identify the snippet or component name, template expression, and relevant Zig
type, for example `unknown field 'titel'` in `post.titel` on `Post`.

The comptime representation is a compact AST equivalent to:

```zig
const Node = union(enum) {
    text,
    expression,
    raw_expression,
    if_block,
    for_block,
    snippet_declaration,
    component,
};

const Expr = union(enum) {
    literal,
    path,
};
```

Paths retain parsed segments. Parsed nodes and component registrations are
comptime-known; runtime rendering only resolves values and writes output.

## 7. Runtime Rendering

The renderer walks the parsed representation and performs only these runtime
operations:

```text
text        -> writer.writeAll
expression  -> resolve, escape, write
raw         -> resolve, write
if          -> evaluate, render selected branch
for         -> iterate, render body for each element
snippet      -> produce no output
component   -> resolve fragment, assemble child context, render child template
```

It avoids tokenization, grammar parsing, filesystem template lookup, dynamic
objects, and unnecessary intermediate strings. Writer errors propagate to the
caller.

## 8. Source Layout and Verification

The initial implementation should remain focused and may use this layout:

```text
src/template/
    root.zig
    ast.zig
    parser.zig
    expression.zig
    escape.zig
    render.zig
    component.zig
```

Tests must cover inline multiline and `@embedFile` sources; escaped and raw
interpolation; numbers and nested fields; boolean `if`, `if`/`else`, optional
capture, loops, and nested loops; basic, nested, and argument-bearing
components; local snippets with positional and named arguments; invocation
before and after declaration; snippets in loops; nested lexical scope and
shadowing; layout composition; independent fragment rendering; and compile
failures for malformed templates, unknown fields, invalid conditions, invalid
iteration, missing components, duplicate snippets, and invalid snippet calls.

## 9. Design Principle

The engine optimizes for:

> Static markup structure, strongly typed Zig data, compile-time validation,
> and minimal runtime work.

It deliberately remains smaller than Jinja, Liquid, and Handlebars.
