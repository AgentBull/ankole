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

Read `~/DESIGN.md` completely with `read_file` before applying the internal VIS. It resolves to the real uppercase file for the current Agent. Treat it as read-only; operators manage it through Ankole Console.

Use this routing contract:

- When the user explicitly asks for the internal design system or VIS, read and apply every relevant rule.
- When the user explicitly opts out or asks for a different style instead, follow that direction without applying the internal VIS.
- When no style source is specified, decide whether the internal VIS would improve the result. A request to beautify or improve layout requires deliberate styling, but does not by itself require the internal VIS.

Interpret optional YAML frontmatter as exact design tokens and Markdown prose as intent, rationale, and usage guidance. Translate relevant rules into the artifact's medium instead of forcing web-specific details onto slides, documents, spreadsheets, PDFs, charts, or images. The artifact skill remains authoritative for file construction, accessibility, and verification.

The document always carries a usable VIS: installations ship with Ankole's factory-default visual identity, and operators replace the content in Console when the installation adopts its own.

## General Design Principles

> If the user has already provided other design guidance, match that first.

Before styling any layout, resolve its underlying structure: how elements group, what grid and axis they align to, where the eye enters and flows, and where whitespace is deliberately placed as a structural element — not leftover space. Then organize the page with one dominant compositional device chosen from: repetition (identical units), similarity (shared skeleton, controlled variation), gradation (one element changing by a single rule), radiation (spreading from or converging to a focal point), axial arrangement (modules along a spine), concentration (intentional dense-vs-sparse tension), contrast (one decisive difference in size, direction, density, or color), or rhythm (recurring motifs at intervals across pages). Keep contrast singular and strong, keep same-group elements strictly uniform, constrain colors to a pre-defined palette, and let order be established before variation is introduced. Style is the skin; composition is the skeleton.

Less is more. Restraint is a discipline, not a deficiency: limit typefaces to one or two families, colors to a small pre-defined palette, and styling devices (borders, shadows, icons, decorations) to the minimum needed to express structure. Every additional variant of font, color, or ornament dilutes hierarchy and adds noise. Beauty emerges from order — from consistent spacing, aligned elements, and disciplined repetition — not from accumulation. When in doubt, remove; if the composition collapses without a decorative element, the composition was never sound.
