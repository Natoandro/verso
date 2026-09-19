# Template Renderer Stack Overflow Incident

Status: resolved

Date: 2026-09-19 to 2026-09-20

Affected area: authenticated editorial rendering, especially the
`section_card` component in `/admin/editor`

## Summary

Rendering an editor document containing a section card caused the Verso worker
process to abort with a segmentation fault. The request reached the template
renderer and emitted the surrounding page logs, but crashed before the first
instruction in the `section_card` template body could execute.

The failure was a stack-frame explosion caused by compile-time template data
being materialized as a runtime local. The final `section_card.render` frame
reserved approximately 9.25 MiB (`0x93fcb0`) before rendering any output. The
fix preserves compile-time parsing and validation, passes the parsed AST
directly as a comptime argument, and executes each lexical range through a
small comptime-generated operation table.

## Symptoms

The server logged successful static asset requests and entered the registered
`section_card` component. All component arguments were bound successfully. The
process then aborted with a segmentation fault at the template entry point,
rather than returning an application error or a stale-revision response.

The important diagnostic distinction was that the crash happened before the
child template's first runtime log line. This initially made invalid scope
links or an incorrectly bound section value plausible, but the crash location
was actually the function prologue and stack probing code.

## Investigation

The investigation used temporary debug-only renderer logging and a core dump.
The logs recorded template entry, loop capture, component binding, and child
render hand-offs. They established that:

1. The parent editor template reached the `section_card` component.
2. All seven component parameters were resolved and bound.
3. The crash occurred while entering `section_card.render`, before its body
   could write output.

The core dump and disassembly provided the decisive evidence. The generated
function began with a stack allocation equivalent to:

```text
sub $0x93fcb0, %rsp
```

and then copied approximately `0x93fc58` bytes from static data into that
stack frame with `rep movsb`. The copied object was the source-sized parsed AST,
not the user document, component context, or lexical scope chain.

The first TPL-006 implementation replaced the old whole-template `inline while`
renderer with runtime operation dispatch, but still contained this pattern in
`Template.render`:

```zig
const parsed = comptime parser.parse(source);
renderer.renderNodes(writer, parsed.nodes, parsed.count, components, context);
```

Although parsing was evaluated at comptime, keeping the complete `Parsed` value
in a function local allowed the compiler to materialize its source-sized node
buffer in the runtime frame. Operation dispatch alone therefore did not remove
the stack hazard.

## Root cause

The parser represents a template as a comptime `Parsed` value whose node
storage is sized from the source capacity. The renderer must use that value as
compile-time input, not as a runtime local.

Two independent sources of generated stack growth were involved:

1. The original `inline while` renderer expanded every static node into one
   generated function, making the function body and frame grow with template
   size.
2. The initial operation-table renderer still copied the complete parsed AST
   into the runtime `Template.render` frame, retaining source-length-proportional
   stack usage even though the node operations were dispatched at runtime.

The failure was not caused by `section_card`'s field types, component argument
binding, borrowed scope links, invalid document data, or a need for runtime
template parsing.

## Resolution

The renderer now applies both parts of the bounded execution design:

- `src/template/execution.zig` generates a comptime operation table for each
  lexical AST range. Runtime rendering carries only a program counter and a
  pointer to the current typed context. Each operation immediately restores
  the exact validated context type before performing path resolution.
- `Template.render` passes `comptime parser.parse(source)` directly to
  `renderNodes`; it does not assign the complete parsed AST to a runtime local.
- Nested block ranges retain borrowed lexical scope links and render
  synchronously, so scope lifetime remains bounded by lexical nesting depth.
- Temporary renderer tracing was removed after the failure was understood. It
  was investigation instrumentation, not part of the application logging
  contract.

## Regression coverage

The template suite now renders a 6 KiB template containing 768 static nodes
through the lowered execution path. This test exercises source-size-dependent
stack behavior while retaining the ordinary typed interpolation path.

Validation performed after the fix:

- `zig build` completed successfully.
- The direct template suite passed all 15 tests.
- `zig build test -j1` completed successfully; the expected migration-drift
  diagnostic is emitted by the migration-ledger test.
- Disassembly of the rebuilt `section_card.render` entry showed a 112-byte
  (`0x70`) frame instead of the previous approximately 9.25 MiB frame.

## Lessons and follow-up

- A comptime expression can still produce a runtime copy if its complete value
  is assigned to a runtime local. The boundary between compile-time data and
  runtime storage must be checked in generated machine code when stack usage is
  the concern.
- A large-template regression must cover both operation dispatch and the AST
  hand-off into the renderer; testing only a flat operation loop is insufficient
  if the parsed representation is still copied at the template entry point.
- Future renderer changes must preserve the stack invariant documented in
  `docs/design/template-engine.md` and retain a large-template regression.
- The next planned template task is TPL-007, integrating the renderer into
  additional server-rendering paths while preserving the existing safety and
  cache boundaries.
