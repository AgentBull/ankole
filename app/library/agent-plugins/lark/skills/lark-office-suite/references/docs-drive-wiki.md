# Docs, Drive, and Wiki

## Docs

Start with `lark-cli docs --help`. Prefer the high-level shortcuts for document content:

```bash
lark-cli docs +fetch --doc <url-or-token> --as bot --format json
lark-cli docs +create --content '<title>Status</title><p>On track.</p>' --as bot --format json
lark-cli docs +update --doc <url-or-token> --command append --content '<p>Next step</p>' --as bot --format json
```

The bot-capable Docs surface includes create, fetch, structured updates, history, media insertion/download, and document resources when command help permits it. Fetch with block IDs before precise block mutations. After overwrite, replace, delete, move, or copy operations, refetch before reusing block IDs.

When a task requires an exact document title, include an explicit `<title>...</title>` before the body in every create or full-document overwrite payload. A later Markdown overwrite can replace the title from the create operation with the first heading. After each title-sensitive write, fetch the same document and compare the returned document title field with the required title. A matching string elsewhere in the response or body does not verify the title.

For create or update payload syntax, read the installed version-matched format reference named by command help:

```bash
lark-cli skills read lark-doc references/lark-doc-xml.md
lark-cli skills read lark-doc references/lark-doc-md.md
```

Read the Markdown reference only when using `--doc-format markdown`. Use these references only for content grammar and block semantics; this skill's bot-only runtime and permission rules remain authoritative.

Use Drive search to find documents; do not depend on a person-scoped Docs search shortcut. When a fetched document contains embedded Sheet, Base, or Whiteboard tokens, route those tokens to the matching service rather than treating the embed as plain text.

## Drive

Start with `lark-cli drive --help`. The bot-capable surface covers files, folders, search, copy, move, delete, upload, download, import, export, versions, comments, and members where the bot has access.

```bash
lark-cli drive +search --query "quarterly plan" --as bot --format json
lark-cli drive files list --folder-token <folder_token> --page-all --as bot --format json
lark-cli drive +upload --file artifacts/report.pdf --folder-token <folder_token> --as bot --format json
lark-cli drive +download --file-token <file_token> --output lark-downloads/report.pdf --as bot --format json
lark-cli drive files copy --help
```

Use typed resources and schema for copy, move, delete, comments, permissions, and version operations. Prefer a native Drive copy over fetch-and-recreate when preserving an existing cloud document. Imports and exports hand off through relative local paths.

## Wiki

Start with `lark-cli wiki --help`. Supported bot workflows include listing visible spaces, getting a space, listing/searching nodes, creating/copying/moving nodes, resolving a Wiki token to its underlying object, and managing members when command help lists bot.

```bash
lark-cli wiki +space-list --as bot --format json
lark-cli wiki +node-list --space-id <space_id> --page-all --as bot --format json
lark-cli wiki +node-get --node-token <node_token> --as bot --format json
```

Creating a personal knowledge space is out of scope. Work inside spaces already visible to the application. After resolving a Wiki node, use the underlying Docs, Sheets, Base, or other service for content operations.
