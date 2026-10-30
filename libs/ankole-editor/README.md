# Ankole Editor

`@ankole/block-editor` is Ankole's internal block-editor library at
`libs/ankole-editor`. Distributed as a private Bun workspace package, its
TypeScript source is compiled directly by each host application, which shares
React 19.3.1 with the editor.

See the [Specification](SPEC.md) for document formats, editing behavior, public
APIs, host responsibilities, and browser support. Within that boundary, this
package handles editing and document conversion, while hosts manage persistence,
document selection, and error recovery. Hosts can also pass `labels` to
translate the UI: any omitted keys fall back to the built-in Chinese defaults,
and updating `labels` at runtime keeps the current document, selection, and undo
history intact. Code blocks highlight through Kirari and carry a language
picker, wrap toggle, and copy control; formula blocks render LaTeX through
Temml; Mermaid blocks render `mermaid` fences through Pele with a source and
diagram split view. These ship with the package and need no host configuration.
Through `EditorHost` hooks, hosts also supply inline mentions (`@` and `＠`
pickers for pages and principals, mounted inline via `mountMention`) and
discussion comment anchors (native `Comment` marks across rich text and code,
live draft selection tracking via `trackCommentSelection`, and resolved-thread
presentation via `resolvedCommentIDs`). The `playground/` directory provides a
standalone example host and is excluded from the package tarball.

## Use in an Ankole workspace

In a React host, declare the editor, UI Kit, and React dependencies in the
host's `package.json`:

```json
{
  "dependencies": {
    "@ankole/block-editor": "workspace:*",
    "@ankole/uikit": "workspace:*",
    "react": "19.3.1",
    "react-dom": "19.3.1"
  }
}
```

Then run `bun install` from the Ankole repository root. Because the root
manifest and `bun.lock` manage workspace dependencies, `libs/ankole-editor`
needs no lockfile of its own.

Import only from the public entry points:

| Entry point | Purpose |
| --- | --- |
| `@ankole/block-editor` | React editor component and current-editor hook |
| `@ankole/block-editor/document` | Markdown and XML readers and writers |
| `@ankole/block-editor/editor` | Page sessions, collaboration, host types, and editing commands |
| `@ankole/block-editor/styles.css` | Styles scoped to the editor and its overlays |

In the host's Tailwind CSS entry file, import UI Kit styles before editor
styles:

```css
@import '@ankole/uikit/styles.css';
@import '@ankole/block-editor/styles.css';
```

Hosts use Tailwind CSS 4 to scan their own components, and their bundlers must
be configured to deduplicate `react` and `react-dom` to a single instance of
each.

```tsx
import { BlockEditor } from '@ankole/block-editor'
import { PageSession } from '@ankole/block-editor/editor'

export function DocumentEditor() {
  return (
    <BlockEditor
      initial="# Notes"
      onReady={editor => {
        const page = new PageSession(editor)
        // Read snapshots through page.read(); the host owns storage.
        return () => page.dispose()
      }}
    />
  )
}
```

`BlockEditor` reads `initial` only on mount. To update the document afterward,
call `PageSession.apply()`, or pass a new React `key` when mounting a fresh
editor instance. Revision numbers are scoped to a single editor instance, so
always read a fresh snapshot after replacing the instance. For IME composition
conflicts and stale-write rejection, see [SPEC.md](SPEC.md).

`bun run --filter @ankole/block-editor test:package` verifies the tarball
installation workflow for standalone consumers.

## Develop and verify

Run checks from the Ankole repository root:

```sh
bun install --frozen-lockfile
bun run --filter @ankole/block-editor type-check
bun run --filter @ankole/block-editor lint
bun run --filter @ankole/block-editor test
bun run --filter @ankole/block-editor test:upstream
bun run --filter @ankole/block-editor test:package
```

Because this is a source package, `build` runs type-checking rather than
emitting compiled artifacts. The example host in `playground/` has its own dev
server, build, and end-to-end suite:

```sh
bun run --filter @ankole/block-editor dev
bun run --filter @ankole/block-editor build:playground
bun run --filter @ankole/block-editor test:e2e
```

The development server listens at <http://127.0.0.1:3046>, and the multi-editor
embedding example is served at <http://127.0.0.1:3046/playground/embedded.html>.

If Playwright browsers are not installed yet, run `test:e2e:install` first.
Browser tests, tarball-consumer checks, and native browser compatibility suites
run separately from the fast unit test suite; see [SPEC.md](SPEC.md) for
platform-skipped cases and known browser differences.

## Editing engine and licenses

The editing engine is a fork of Wordgard in `src/core`, distributed under its
[MIT license](src/core/LICENSE). See the [core README](src/core/README.md) for
upstream provenance and local changes, and [upstream/NOTICE.md](upstream/NOTICE.md)
for third-party test fixtures and their licenses.
