# Slides, Whiteboard, and Lark Markdown

## Slides

Start with `lark-cli slides --help`. Use Slides for Lark cloud presentations and `presentation_token` values.

```bash
lark-cli slides +create --title "Weekly Review" --slides @slides.json --as bot --format json
lark-cli slides +xml-get --presentation <url-or-token> --output lark-slides/review.xml --as bot --format json
lark-cli slides +replace-slide --presentation <url-or-token> --slide-id <slide_id> --parts @parts.json --as bot --format json
```

Use the installed shortcut and typed-resource help for page creation, element insertion, text/image updates, ordering, thumbnail/export, and batch mutations. Read presentation structure before editing and preserve element IDs across a batch only when the operation guarantees they remain valid.

## Whiteboard

Start with `lark-cli whiteboard --help`. Use Whiteboard for querying or updating an existing Lark canvas, including supported DSL, Mermaid, or PlantUML inputs.

```bash
lark-cli whiteboard +query --whiteboard-token <whiteboard_token> --output_as raw --as bot --format json
lark-cli whiteboard +update --whiteboard-token <whiteboard_token> --input_format mermaid --source @diagram.mmd --idempotent-token <stable-token> --as bot --format json
```

Confirm the installed flags with help. If a Whiteboard is embedded in a Doc, use Docs to discover/download its media and Whiteboard to mutate the canvas. Keep source files relative to the workspace.

## Lark Markdown

Start with `lark-cli markdown --help`. This service owns Drive-native Markdown files: create, fetch, diff, overwrite, and patch. It is not a generic local Markdown renderer.

```bash
lark-cli markdown +fetch --file-token <file_token> --as bot --format json
lark-cli markdown +fetch --file-token <file_token> --output lark-markdown/note.md --as bot --format json
lark-cli markdown +diff --help
lark-cli markdown +overwrite --help
lark-cli markdown +patch --help
```

Inspect the selected subcommand's help before a write. Do not route ordinary local `.md` editing here; use this service only when the file is a Drive Markdown object or the task explicitly imports/exports one through a relative local path.
