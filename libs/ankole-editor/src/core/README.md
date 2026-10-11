# Core

This directory holds the editing engine. It is a fork of [Wordgard](https://code.haverbeke.berlin/wordgard/wordgard) at commit 7993139 (2026-10-07), under the MIT license in [LICENSE](LICENSE).

The fork is part of the package source. It uses the package's TypeScript settings, formatting and test runners. It does not follow upstream mechanically: to take an upstream change, apply it by hand and add a test.

## Changes from upstream

Source form:

- Imports between modules use relative paths. The `highlight-code` and `placeholder` modules are removed; the page draws its own empty-page hint.
- Vite (Oxc) and Bun compile the source directly:
  - `Transaction.extender` and `Transaction.appender` are static fields, not mutable namespace exports.
  - Enums are plain `enum`, not `const enum`.
  - No method of a class inside a namespace uses `this` in a default parameter.
- Indexed access that the code knows is in range has a non-null assertion (`noUncheckedIndexedAccess`).
- Documentation comments use JSDoc, not `///`.
- The code passes the repository lint rules in `.oxlintrc.json`: for example `const` for bindings that are not reassigned, no assignments in conditions, no aliases of `this`, and no unused variables or parameters. Debug logging switches and FIXME notes are removed.

Input:

- Between a `beforeinput` event that the browser applies itself and its `input` event, `flush()` does nothing and `focus()` does not move the DOM selection. A redraw in that time put the browser's change next to the drawn one, and later typing went between them.
- Keydown and `beforeinput` read a DOM selection that the editor has not read yet, without a flush (`InputState.readNewSelection`). A selection that the editor set and has not drawn yet wins (`DOMObserver.editorSelectionPending`; selections read from the DOM carry `selectionFromDOM`).
- Safari commits a composition with `deleteCompositionText` and `insertFromComposition`. Both apply to the document. On desktop Safari, the key event that follows the end of a composition (for example Enter) does not run as a command.
- When a composition starts, the editor first draws a selection that it set and has not drawn yet, so that the browser composes there. A composition that starts between blocks first gets an empty paragraph.
- `insertReplacementText` and `insertFromYank` accept `data` as well as `dataTransfer`. A non-cancelable replacement, or an `input` event without a matching `beforeinput`, is read from the DOM when it changes text inside existing text nodes.
- Backspace takes the last combining mark off a character without emoji, as Chromium and Firefox do.
- Word selection and word motion use `Intl.Segmenter` without a fallback. Every supported browser has it.

Clipboard:

- A `paste` event handler shares its code with `insertFromPaste`. Copy and paste read a DOM selection that the editor has not read yet.
- Copied HTML carries the exact slice as JSON in a `wg-slice` attribute, which a paste reads first. Text-only copies get a wrapping span to carry it.
- Clipboard filters receive and return the slice context.
- In code, pasted text is literal, with line breaks as line break nodes. HTML without a text form pastes into code as its text.
- A cut deletes through the `deleteCut` command, so that extensions can change how a cut deletes.
- HTML parsing: each kind of child counts once when the parser guesses the parent of a slice; `display: inline` elements do not start a block; nested blocks lose stray spaces at the slice edges; a `<br>` that only keeps an empty line visible is dropped. The default schema reads `<b>`, `<i>`, `<del>`, `<strike>`, bold only from `bold` and weight 700, multi-value `text-decoration`, and `vertical-align` for subscript and superscript.

Fixes:

- `Wordgard.logException` called itself and overflowed the stack. It now reports to the exception sink.

Document and selection:

- `cursorBarrier: 'empty'` makes a container a cursor barrier only while it is empty, so that an empty container holds a caret and two filled containers have no position between them. Such an empty container that can hold a text block directly gets a trailing `<br>`, and Up and Down stop in it.
- `GardSelection.Text.map` keeps a backward selection backward.
- `CodeBlockLanguage` stays on both parts of a split code block.
- Tables: `Node.Role.Table` and `Node.Role.TableRow` mark table and row types. Cell selection and the table map use these roles, accept rows of different lengths and empty tables, and keep a cursor in an empty row or table.

## Tests

- `test/core`: unit tests, run by `bun run test`.
- `test/core/browser`: browser tests, run in Chromium, Firefox and WebKit by `e2e/core.spec.ts`.
