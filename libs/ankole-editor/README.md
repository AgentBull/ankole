# Ankole Editor

`@ankole/block-editor` is the internal block editor library at `libs/ankole-editor`.
It is a private Bun workspace package. Hosts compile its TypeScript source and
share React 19.3.0 with the editor.

[Specification](SPEC.md) defines the document formats, editing behavior,
public APIs, host responsibilities, and supported browsers. The package owns
editing and document conversion. Hosts own persistence, document selection,
and recovery. Hosts can pass `labels` to translate the interface. The editor
keeps Chinese defaults for omitted labels. A label change preserves the current
document, selection, and undo history. `playground/` is an example host and is
not in the package tarball.

## Use in an Ankole workspace

For a React host, declare the editor, UI Kit, and React dependencies in the
host's `package.json`:

```json
{
  "dependencies": {
    "@ankole/block-editor": "workspace:*",
    "@ankole/uikit": "workspace:*",
    "react": "19.3.0",
    "react-dom": "19.3.0"
  }
}
```

Run `bun install` from the Ankole root. The root manifest and `bun.lock` own the
workspace dependencies and the Markdown writer patch. No package-local lockfile
is required.

Use the public entry points:

| Entry point | Purpose |
| --- | --- |
| `@ankole/block-editor` | React editor and the current editor hook |
| `@ankole/block-editor/document` | Markdown and XML readers and writers |
| `@ankole/block-editor/editor` | Page sessions, collaboration, host types, and editing commands |
| `@ankole/block-editor/styles.css` | Styles scoped to the editor and its overlays |

Import UI Kit styles before editor styles in the host's Tailwind CSS entry:

```css
@import '@ankole/uikit/styles.css';
@import '@ankole/block-editor/styles.css';
```

The host uses Tailwind CSS 4 and scans its own components. Configure the host
bundler to share one `react` and one `react-dom` instance.

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

`initial` is read once. Use `PageSession.apply()` for later document writes and a
new React key for a new editor instance. A revision belongs to one instance;
read a new snapshot when the instance changes. See the specification for
composition conflicts and stale-write rejection.

A separate tarball consumer must declare and apply the patch from `patches/` in
its own `patchedDependencies`. `test:package` checks that installation path.

## Develop and verify

Run these commands from the Ankole root:

```sh
bun install --frozen-lockfile
bun run --filter @ankole/block-editor type-check
bun run --filter @ankole/block-editor lint
bun run --filter @ankole/block-editor test
bun run --filter @ankole/block-editor test:upstream
bun run --filter @ankole/block-editor test:package
```

`build` checks types because this is a source package. The example host has a
separate build:

```sh
bun run --filter @ankole/block-editor dev
bun run --filter @ankole/block-editor build:playground
bun run --filter @ankole/block-editor test:e2e
```

The development server is at <http://127.0.0.1:3046>. The embedding example is at
<http://127.0.0.1:3046/playground/embedded.html>.

Install browser binaries with `test:e2e:install` when needed. Browser tests,
package-consumer checks, and native compatibility checks run separately from
the fast unit suite. See the specification for skipped cases and known browser
test differences.

## Editing engine and licenses

The editing engine is the Wordgard fork in `src/core`, under its
[MIT license](src/core/LICENSE). Its origin and local changes are in the
[core README](src/core/README.md). Upstream fixtures and their licenses are in
[upstream/NOTICE.md](upstream/NOTICE.md).
