# Core

This directory contains the editing engine, forked from
[Wordgard](https://code.haverbeke.berlin/wordgard/wordgard) at commit `2d2d213`
(2026-11-13) under the MIT license in [LICENSE](LICENSE).

The fork lives inside `@ankole/block-editor` and shares the package's TypeScript
compiler settings, formatter, and test runners. Upstream changes are never
merged automatically; port individual changes by hand and accompany each one
with a regression test.

## Changes from upstream

Source layout and toolchain:

- Internal imports use relative paths. The `highlight-code`, `placeholder`, and
  `inputrule` modules are omitted because `BlockEditor` renders its own
  empty-page prompt and its own typing shortcuts; `decoratePlots` is also
  omitted, so upstream's repeated-replacement fix for that helper does not
  apply. Facets, fields, effects, annotations, roles, and groups print with
  their default string form.
- Source files compile directly under Vite (Oxc) and Bun:
  - `Transaction.extender` and `Transaction.appender` are static class fields
    rather than mutable namespace exports.
  - Enums are standard `enum` declarations rather than `const enum`.
  - Methods on classes declared inside namespaces avoid referencing `this` in
    default parameter initializers.
- In-bounds array lookups carry explicit non-null assertions to satisfy
  `noUncheckedIndexedAccess`.
- Because `isolatedModules` is enabled, the `Shape` namespace is exported with
  `export type`.
- Doc comments use JSDoc (`/** … */`) instead of `///`.
- All files conform to `.oxlintrc.json`: non-reassigned bindings use `const`,
  conditions contain no assignments, `this` is never aliased, unused variables
  and parameters are removed, and upstream debug switches and `FIXME` comments
  are stripped.

Input handling:

- Between a browser-handled `beforeinput` event and its matching `input` event,
  `flush()` is a no-op and `focus()` leaves the DOM selection untouched;
  re-rendering during that window would place the browser's mutation beside the
  rendered node and drop subsequent keystrokes between them.
- `keydown` and `beforeinput` read any unconsumed DOM selection without flushing
  (`InputState.readNewSelection`), unless the editor has queued a programmatic
  selection that is not yet drawn (`DOMObserver.editorSelectionPending` takes
  precedence over selections tagged with `selectionFromDOM`).
- Plain character typing inserts at that current selection with its active
  marks, because Chromium can report a stale `getTargetRanges()` span after a
  keyboard command moves the caret; replacement and IME composition events still
  honor their own target ranges.
- On Safari, committing an IME composition fires `deleteCompositionText`
  followed by `insertFromComposition`; both apply to the document, and on
  desktop Safari the trailing `keydown` (such as Enter) is suppressed as an
  editor command.
- Starting an IME composition flushes any pending programmatic selection first
  so the browser composes at the intended position, and opens an empty paragraph
  inside an empty block container without replacing that container, grouping the
  wrapper with the composition's undo step. When the user clears all preedit
  characters mid-composition, the editor removes the composed text without
  inserting a zero-length text leaf and keeps `InputState.composing` active
  while focus stays in editable DOM. An uncommitted `compositionstart` with zero
  changes does not claim an unchanged text node as a composition target, and
  primary-button `mousedown` and `blur` end any lingering `InputState.composing`
  state when the browser omits `compositionend` (deferring active compositions
  across a microtask on `blur` so DOM removal reaches `disconnect()` before
  completion).
- When `contentDOM` receives non-pointer focus with no pending selection change
  and the browser leaves the selection outside `contentDOM` or reset to its
  start, `focus` synchronously restores `state.selection` rather than filtering
  `DOMObserver.pollSelection` across a post-focus time window, so explicit DOM
  selections placed at the document start immediately after focus are still read.
- `insertReplacementText` and `insertFromYank` read text from `data` when
  `dataTransfer` is absent. Non-cancelable replacements—and `input` events that
  arrive without a preceding `beforeinput`—are reconciled from the DOM whenever
  the mutation stays within existing text nodes.
- For non-emoji characters with combining marks, Backspace removes only the
  final combining mark, matching Chromium and Firefox behavior.
- Word selection and word motion rely directly on `Intl.Segmenter` without a
  fallback, as every supported browser implements it.
- Key bindings normalize modifier names to `Shift`, `Alt`, `Ctrl`, `Cmd`,
  `Meta`, and `Mod` so the stored Meta modifier matches `KeyboardEvent` on each
  OS (`Meta-` on macOS and `Cmd-` elsewhere, whereas upstream inverts the two).

Clipboard:

- The `paste` listener shares its implementation with `insertFromPaste`, and
  both `copy` and `paste` read any unconsumed DOM selection first.
- Copied HTML embeds the exact serialized slice as JSON in a `wg-slice`
  attribute (wrapping plain-text copies in a `<span>` so they can carry it), and
  paste prefers `wg-slice` before falling back to HTML parsing. `readClipboard`
  takes a `DataTransfer`, so `clipboardDataParser` can see every clipboard
  type. `Wordgard.paste` builds a transfer from the HTML and plain text it is
  given.
- Inside code blocks, pasted content is inserted as literal text with line
  breaks converted to line-break nodes; HTML-only clipboards fall back to
  extracted text.
- Cut delegates deletion to the `deleteCut` command so extensions can customize
  cut behavior.
- HTML paste normalization counts each child node kind once when inferring a
  slice wrapper, keeps `display: inline` elements inline, trims stray edge
  spaces on nested blocks, and drops trailing placeholder `<br>` elements on
  empty lines. The default schema recognizes `<b>`, `<i>`, `<del>`, and
  `<strike>`, maps CSS `font-weight` to bold only for `bold` and `700`, parses
  multi-token `text-decoration` values, and maps `vertical-align` to subscript
  and superscript.

Bug fixes:

- `Wordgard.logException` forwards errors to the configured exception sink
  instead of recursing into itself and overflowing the call stack.
- States without custom key-binding providers still apply the default keymap,
  reading the keymap facet optionally rather than requiring it on the state.
- Window `focus` and `blur` events schedule focus-state updates alongside
  `contentDOM` focus changes, and regaining focus (`isFocusChange` `true`)
  synchronizes the native DOM `Selection` with `state.selection` so a selection
  change flushed before focus settled collapses any prior DOM range highlight.
- `PointSet` converts relative coordinates across chunk origins and rebases a
  chunk's `start` when out-of-order insertion crosses chunks or precedes a
  chunk's first point, and `PointCursor.goto` compares absolute positions and
  rewinds across equal-side points down to position `0`.

Document and selection:

- `cursorBarrier: 'empty'` treats a container as a cursor barrier only while
  empty—allowing an empty container to hold the caret while avoiding dead cursor
  positions between adjacent non-empty containers. Empty containers that can
  hold a text block directly render a trailing `<br>` and stop Up/Down arrow
  navigation.
- `GardSelection.Text.map` preserves backward selection direction across
  position mapping.
- Splitting a code block preserves `CodeBlockLanguage` on both halves.
- Table support introduces `Node.Role.Table` and `Node.Role.TableRow` so cell
  selections and table geometry handle ragged rows and empty tables and keep a
  valid cursor position inside an empty row or table.
- Change fitting drops a close token when the change deleted its open token and
  the enclosing level closes later in the input. When the fitter syncs to the
  input context, it keeps two different isolating nodes, such as two columns,
  apart. A local sync point between blocks stays at that position.
- `insertText`, `insertLineBreak`, `enter`, `deleteRange`, `deleteCut`, input
  replacement, WebKit composition deletion, and drop fit their changes locally,
  as `deleteSelection` and paste do.
- A cell selection puts typed, composed, and pasted input in its first cell and
  empties its other cells.
- A correction checks the child lists of every plot that a replaced range left
  in the start document. `Correction.check` takes that start document as an
  optional argument.

## Tests

- `test/core`: fast unit tests run via `bun run test`.
- `test/core/browser`: real-DOM browser tests executed across Chromium, Firefox,
  and WebKit by `e2e/core.spec.ts`.
