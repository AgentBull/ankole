---
name: lark-office-suite
description: "Operate Lark cloud content as this digital employee's application bot: Docs, Drive, Wiki, Sheets, Base, Slides, Whiteboard, Lark Markdown, and read-only Mail. Use for Lark URLs, cloud tokens, and mailbox reads, not local .docx or .xlsx files."
default_enabled: true
category: productivity
tags: [lark, docs, drive, wiki, sheets, base, slides, whiteboard, markdown, mail]
metadata:
  upstream: https://github.com/larksuite/cli/tree/v1.0.69/skills
  upstream_tag: v1.0.69
  validated_against: v1.0.86
  modified_for: Ankole bot-only Agent Plugin runtime
---

# Lark Office Suite

Use `lark-cli` with the application bot identity supplied by this Agent's Lark signal binding. This skill owns Lark cloud content. It never initializes credentials or acts as a human user.

Before the first command, read [references/bot-runtime.md](references/bot-runtime.md). Then read the relevant reference:

- Docs, Drive, and Wiki: [references/docs-drive-wiki.md](references/docs-drive-wiki.md)
- Sheets and Base: [references/sheets-base.md](references/sheets-base.md)
- Slides, Whiteboard, and Lark Markdown: [references/slides-whiteboard-markdown.md](references/slides-whiteboard-markdown.md)
- Mail (read-only bot surface): [references/mail.md](references/mail.md)
- Routing between Lark cloud objects and local Office files: [references/local-artifact-boundary.md](references/local-artifact-boundary.md)
- Capability limits and permission failures: [references/unsupported-and-permissions.md](references/unsupported-and-permissions.md)

## Routing rules

- A Lark/Feishu URL, `doc_token`, `spreadsheet_token`, Base `app_token`, Wiki `node_token`, Drive `file_token`, Slides token, or Whiteboard token belongs here.
- A local `.docx` belongs to `docx`; a local `.xlsx`, `.xls`, `.csv`, or `.tsv` belongs to `xlsx`. Exporting or importing between local and cloud formats can use both skills in sequence, with an explicit relative file handoff.
- Use Docs for document body content, Drive for files/folders/import/export/comments/permissions, Wiki for knowledge-space topology, Sheets for spreadsheet cells and structure, Base for records/schema/automation, Slides for presentations, and Whiteboard for canvases.
- Reading a Lark mailbox (triage, messages, threads, folders, attachment URLs) belongs here. Composing, sending, or mutating mail requires a person's identity and is out of scope.
- Lark Markdown is a Lark rendering and conversion surface. It is not a generic local Markdown editor.

## Completeness contract

Every `lark-cli` command line shown in this skill's references is validated against the image's pinned CLI version at build time. Run a referenced command directly with your values; do not re-verify it with `--help` first.

The references do not hard-code the entire generated API catalog. For an operation the references do not cover:

1. Run `lark-cli <service> --help`.
2. Run command-level `--help` and require bot identity support.
3. Run `lark-cli schema <service>.<resource>.<method>` before typed calls with bodies or query maps.
4. Execute with `--as bot --format json`.

Any installed `docs`, `drive`, `wiki`, `sheets`, `base`, `slides`, `whiteboard`, `markdown`, or `mail` endpoint that explicitly supports bot identity is in scope. Person-only endpoints are unsupported rather than emulated.
