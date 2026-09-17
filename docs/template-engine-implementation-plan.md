# Verso — Template Engine Implementation Plan

## Purpose and conventions

This is the ordered implementation backlog for the compile-time markup
template engine specified in [the template-engine design](design/template-engine.md).
It describes planned, not implemented, work. It supplements the main
[implementation plan](implementation-plan.md) and does not change that plan's
ordering of application features.

`TPL-001` is a rendering-library prerequisite. Each later item is a complete,
tested vertical slice. `[ ]` means not implemented; change it to `[x]` only
when the stated outcome and every nested division are complete.

## 1. Compile-Time Parsing and Output

- [x] **TPL-001 — Parse and stream escaped interpolation**

  Provide the `tmpl.parse` and writer-based `render` API for inline strings and
  `@embedFile` sources. Templates parse into comptime nodes, interpolate
  supported scalar values and nested struct paths, and escape strings directly
  to the writer. Syntax and invalid path access fail during compilation;
  normal rendering performs no parsing or allocation.

  - [x] **AST and parser:** Define the comptime node, expression, and parsed
    path representations; parse text, double-brace interpolation, and
    triple-brace interpolation; reject malformed syntax.
  - [x] **Typed resolution:** Resolve paths through named and anonymous struct
    contexts, including supported pointers to structs, and produce useful
    compile diagnostics for unknown fields and unsupported traversal.
  - [x] **Writer renderer:** Stream text and supported scalar values, with a
    dedicated writer-based HTML escaper and explicit raw-output behavior.
  - [x] **Tests:** Cover inline multiline and embedded-file sources, strings,
    integers, floats, booleans, enums, nested fields, escaping, raw output,
    malformed syntax, and unknown fields.

- [x] **TPL-002 — Add typed control flow**

  Templates support comments, boolean `if`, `if`/`else`, optional capture, and
  nested array/slice loops. Invalid block structure, captures, condition types,
  and iteration types are compile errors.

  - [x] **Block parser:** Parse comments, `if`, `else`, `for`, captures, and
    nested block bodies while rejecting unexpected or unclosed directives.
  - [x] **Scoped resolution:** Model lexical capture scope so branch and loop
    variables resolve with their compile-time Zig types without leaking outside
    their blocks.
  - [x] **Renderer:** Evaluate bools and optionals, unwrap optional captures,
    and iterate arrays and slices without allocating a dynamic context.
  - [x] **Tests:** Cover true/false and else branches, present/absent optional
    captures, loops, nested loops, comments, invalid conditions, invalid
    iteration, malformed captures, and unmatched blocks.

## 2. Components and Composition

- [x] **TPL-003 — Render comptime-registered components**

  A parsed template can register comptime-known components and invoke them with
  named path and literal arguments. Calls construct a typed child context,
  nested components work, and missing components or arguments fail compilation.

  - [x] **Registration API:** Define parse options that accept a comptime
    component struct with declared named parameters and resolve component names
    without a runtime registry.
  - [x] **Call parsing and validation:** Parse component calls and arguments;
    validate registered names, argument names, required inputs, and detectable
    type mismatches against the child template context.
  - [x] **Child rendering:** Assemble the child context from resolved paths and
    literals, then render the child template through the same writer path.
  - [x] **Tests:** Cover a basic component, named path and literal arguments,
    nested components, unknown components, missing arguments, and invalid
    argument types.

- [x] **TPL-004 — Add lexical local snippets**

  Templates can declare zero-output local snippets with explicit parameters and
  invoke them through the ordinary component path. Declarations are
  order-independent within their lexical scope, nested declarations have no
  implicit outer-context capture, and local names take precedence over enclosing
  snippets and external components.

  - [x] **Parser and scope collection:** Parse `snippet` declarations and
    comma-separated parameter lists; collect declarations for every lexical
    body before resolving calls; reject malformed parameters and duplicate names
    in the same scope.
  - [x] **Shared rendering path:** Resolve local declaration ranges by nearest
    lexical scope, then fall back to externally registered components; bind and
    render both through the ordinary component call path.
  - [x] **Argument binding:** Bind positional arguments by declared order and
    named arguments by parameter name into an isolated child context; reject
    missing, excess, unknown, and duplicate bindings.
  - [x] **Tests:** Cover single and multiple snippets, positional and named
    arguments, multiple parameters, calls before and after declaration,
    snippets in loops, nesting, lexical visibility, shadowing, external
    fallback, and all specified invalid declarations and calls.

- [ ] **TPL-005 — Compose layouts and reusable fragments**

  Layouts are composed through the component mechanism, not inheritance. A
  composed page can render header/content/footer while a content template stays
  independently renderable as an HTMX fragment.

  - [ ] **Composition API:** Define the smallest comptime `with`-style API for
    binding layout component slots without adding a separate inheritance model.
  - [ ] **Context contract:** Preserve typed outer context and validate the
    context each composed child requires when its renderer is instantiated.
  - [ ] **Rendering integration:** Render layout slots via the ordinary
    component path and ensure composition creates no runtime lookup or parsing.
  - [ ] **Tests:** Cover layout plus content, header/footer slots, reused
    components, and independent fragment rendering.

## 3. Integration and Completion

- [ ] **TPL-006 — Integrate templates into server rendering**

  Public, editorial, and HTMX renderers use developer-authored templates while
  preserving the existing document-content safety and cache boundaries. The
  allocation convenience API, if included, is implemented on the writer API.

  - [ ] **Render integration:** Replace fixed application markup only where a
    completed rendering slice needs templates; keep document Markdown and
    author-controlled data on their existing safe rendering path.
  - [ ] **Cache and preview boundaries:** Verify public rendered output can be
    atomically cached while authenticated draft previews remain
    `private, no-store` and no template operation mutates canonical content.
  - [ ] **Convenience API:** Add `renderAlloc` only as a small collector around
    writer rendering, with equivalent output and error behavior.
  - [ ] **Integration tests and docs:** Verify complete pages and HTMX fragments
    through their real render paths, document supported template syntax, and
    confirm no runtime parsing or template lookup occurs on requests.
