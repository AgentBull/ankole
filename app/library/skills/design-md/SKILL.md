---
name: design-md
description: "Use for visual artifacts or beautification when internal VIS may apply. Required when the user requests internal VIS; skip on opt-out or another specified style instead; optional when no style source is given."
default_enabled: true
category: creative
tags: [design, vis, visual-identity, artifacts]
metadata:
  upstream: https://github.com/google-labs-code/design.md
  modified_for: Ankole DESIGN.md consumption
---

# Use the internal visual identity

This skill consumes the current Agent's `DESIGN.md`. It does not create, edit, lint, diff, or export that document.

Read `/workspace/.ankole/agent-library/DESIGN.md` completely with `read_file` before applying the internal VIS. Treat the file as read-only; operators manage it through Ankole Console.

Use this routing contract:

- When the user explicitly asks for the internal design system or VIS, read and apply every relevant rule.
- When the user explicitly opts out or asks for a different style instead, follow that direction without applying the internal VIS.
- When no style source is specified, decide whether the internal VIS would improve the result. A request to beautify or improve layout requires deliberate styling, but does not by itself require the internal VIS.

Interpret optional YAML frontmatter as exact design tokens and Markdown prose as intent, rationale, and usage guidance. Translate relevant rules into the artifact's medium instead of forcing web-specific details onto slides, documents, spreadsheets, PDFs, charts, or images. The artifact skill remains authoritative for file construction, accessibility, and verification.

The document always carries a usable VIS: installations ship with Ankole's factory-default visual identity, and operators replace the content in Console when the installation adopts its own.
