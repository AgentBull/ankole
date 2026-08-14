---
name: pptx
description: "Create, read, edit, replicate, combine, or split PowerPoint (.pptx) decks. Use whenever .pptx is input or output, or supplied Markdown, documents, outlines, PDFs, or reference images must become an editable slide presentation. Lark cloud slides and tokens belong to lark-office-suite."
default_enabled: true
category: productivity
ankole-runtime: background_job
tags: [pptx, slides, presentation, officecli]
---

# PPTX

This Skill turns supplied material into an editable PowerPoint presentation and uses OfficeCLI for the file operations. It owns slide narrative, page selection, layout, typography, visual hierarchy, diagrams, charts, images, and rendering QA.

It can split, merge, reorder, and condense supplied material to make a coherent slide sequence. Preserve the source meaning while doing so. Format supplied notes and footnotes as part of the presentation.

For visual styling, use `design-md` when the user requests the internal design system or VIS. Skip it when the user opts out or chooses another style. Treat it as optional when no style source is specified. The selected style source supplies colors, type, surfaces, and brand rules. A Playbook supplies scene-specific information architecture and page grammar.

## Classify the Work

First determine the purpose of the request:

- Create a PPT: create a new presentation from the user's request, supplied material, or an existing PPTX template.
- Edit a PPT: edit the user's uploaded PPT with local modifications, single-page beautification, or a full visual revision.
- Replicate a PPT: reproduce the appearance of a deck that exists as images, PDF pages, or another non-PPTX format.

Choose one primary mode by what the request wants from the source: Edit when an existing PPTX is the artifact to change, Replicate when the source's appearance is the deliverable, and Create when the source supplies content for a new design.

Then determine the design direction:

- Self-directed design: no preference, or only simple style constraints given; you need to fill in or create the design.
- Design system: the user provides a complete and detailed design scheme covering all color, font, layout, and component specifications.
- Use a template: a template is provided and must be used.
- Style transfer: a style reference source is provided, such as images, PDF pages, screenshots, or web pages.

Use this precedence: user requirements → supplied template → supplied design system → supplied style reference → self-directed design. Self-directed design is the default only when no stronger style source exists.

Then identify the supplied content shape:

- Full document: the user provides a complete Markdown document, paper, report, or other source.
- Outline: the user provides a page-by-page outline, speech script, or similar content.
- Existing deck: the user provides a PPTX to edit or reuse as a template.
- Visual reference: the user provides images, screenshots, PDF pages, or a URL for replication or style transfer.

Use the user's page count when one is specified. Match a page-by-page outline or script unless the user asks to restructure it. Otherwise, decide the page count from the supplied material and the selected Playbook.

## Playbooks

A Playbook adds page organization and presentation grammar for one kind of deck. Before planning the deck, list the PPTX Playbooks:

```bash
bun /repo/app/library/agent-plugins/office/tools/list_playbooks.ts pptx
```

Read the one primary Playbook that best matches the requested deck. Use `poster-infographic` only when the user explicitly requests a poster, infographic, or highly visual single-page or few-page composition. When no Playbook matches, use this Skill alone.

A Playbook may reorganize supplied Markdown into a page sequence and define page types, narrative rhythm, density, and the visual role of figures, diagrams, images, and text. User requirements, an existing template, or a supplied design system take priority over Playbook defaults.

## Plan, Check, Then Build

Before any OfficeCLI edit, turn the supplied content into a page map. Record, for each page:

> source span / page title / page type / role in the sequence / main visual / supporting text / density

Check the page map before building:

- every supplied section has a destination, unless the user explicitly removes it;
- repeated material is intentional;
- the title sequence forms a readable arc;
- the page count follows the user's request or the supplied structure;

Fix the map before opening the output deck. Use section pages only when the narrative changes phase. Vary page skeletons when the material changes role; do not repeat one card grid across the deck.

Preserve the full meaning of the supplied material. You may:

- split one long section across several pages;
- merge short adjacent sections that share one page role;
- reorder sections when this makes the supplied narrative clearer;
- condense prose into headings, callouts, labels, charts, tables, or diagrams;
- move long supporting text into speaker notes when the requested use permits it.

Preserve definitions, constraints, qualifications, numbers, labels, and relationships from the source. If supplied content does not fit legibly, split the page or ask the user to narrow the scope.

## Visual Assets

Use image search or generation tools sensibly to obtain images and place them in suitable positions. If the user's uploaded files contain useful images, use them on suitable pages. When photography is needed and no supplied image fits, download a suitable image from Unsplash or another stock-photo source. When a page needs an original illustration, background, texture, scene, or visual metaphor, use an available image-generation model. Use a coherent icon set when icons make objects, categories, or relationships faster to understand.

Choose each asset after its role appears in the page map. Keep image use selective: each asset should support the page's claim, subject, or reading path, and important imagery should occupy enough area to shape the composition. Keep charts, tables, and relationship diagrams editable; use downloaded or generated images for photographic and illustrative material.

## Templates and Style Transfer

### Using a template

1. Review the existing deck before editing it.
2. Review the pages to understand the template's visual style (color scheme, font style, element characteristics, layout characteristics, content density, etc.).
3. Identify page types; focus on reading special pages such as the cover, summary pages, and section dividers, extracting their page layouts, content structures, reusable components (icons, shapes, SmartArt, reusable body layout schemes, etc.), and element styles (e.g., whitespace/line/card separators, square/rounded corners, etc.).
4. Produce the presentation using the template.

Preserve existing masters, theme, page size, and established layout conventions. Do not replace a real template with a parallel approximation.

### Style transfer

1. Analyze the reference file's visual style (color scheme, font style, element characteristics, layout characteristics, content density, etc.), page layouts, content structures, reusable components (icons, shapes, SmartArt, reusable body layout schemes, etc.), and element styles (e.g., whitespace/line/card separators, square/rounded corners, etc.).
2. When a rendered view of a supplied URL is available, use it to understand the visual effect; page text alone does not establish a visual style.
3. Produce the presentation using the reference file's style characteristics. Reuse supplied illustrations, fonts, font-size hierarchies, and elements when the user's request permits it.

For replication, analyze the reference images to estimate element positions, fonts, sizes, colors, and crops, and replicate them as closely as possible. Crop an original image only when an element cannot be reproduced with editable PowerPoint objects and the user permits reuse.

## OfficeCLI Runtime

Ankole Agent Computer images install OfficeCLI 1.0.144 at build time. Verify the exact runtime:

```bash
officecli --version
```

Require the exact output `1.0.144`. A missing command or a different version means the Worker image and this Skill disagree; a rebuild happens outside this Job, so report the stale runtime as the Job outcome.

### Gotchas

- Help reflects the installed CLI version. When this Skill and help disagree, help is authoritative. Run help before guessing a property, alias, enum value, animation preset, chart type, or canvas control, and after any `UNSUPPORTED props:` or unknown-enum error.
- `officecli help pptx ...` covers schema elements only. Use a top-level command's own help for its syntax, such as `officecli batch --help`, `officecli open --help`, or `officecli view --help`.
- Always quote element paths such as `"/slide[1]/shape[@name=Title]"`; zsh treats unquoted brackets as globs.
- Single-quote values that contain `$`, such as `--prop text='$15M'`. After writing currency or escaped text, use `view text` and compare it character for character.
- The CLI interprets `\n` and `\t` in `text=` values.
- For custom slides, use `layout=blank` and ordinary shapes or text boxes. Slide-level title/text shorthand creates placeholders that some viewers import incorrectly.
- Name important shapes when creating them. Prefer `@name=` selectors to positional shape indexes after any reorder.

```bash
officecli help pptx
officecli help pptx <element>
officecli help pptx <verb> <element>
officecli help pptx <element> --json
```

Run structural operations incrementally. After adding a slide, chart, animation, or connector, inspect the affected slide before adding more elements.

## File Lifecycle

Start wide, then narrow:

```bash
officecli view "$FILE" outline
officecli view "$FILE" annotated
officecli view "$FILE" text --start 1 --end 5
officecli view "$FILE" issues
officecli view "$FILE" stats
```

Use stable shape names and quoted selectors:

```bash
officecli get "$FILE" "/slide[1]" --depth 1
officecli get "$FILE" "/slide[1]/shape[@name=Title]"
officecli query "$FILE" 'picture:no-alt'
```

For a new deck, create and open it. For an existing deck, inspect it before editing:

```bash
officecli create "$FILE"
officecli open "$FILE"
```

Build in display order. Add the slide and its background, then the title, then the main visual, then supporting elements. Check the slide structure after each structural change.

Save only when a non-OfficeCLI program must read the current file, at a delivery boundary, or before closing:

```bash
officecli save "$FILE"
officecli close "$FILE"
```

## Construction Rules

- Use the source deck's canvas and masters when editing or using a template. For a new deck, set the slide background and text colors explicitly.
- Use the font hierarchy, grid, and color system from the user, template, design system, or style reference. Use the selected Playbook for scene-specific page rhythm, density, and content-object roles. Do not apply one universal slide font size to every scene.
- Keep body text readable at the requested viewing distance. Split a page before shrinking text below the selected scene's readable range.
- Use whitespace, alignment, type, rules, and image composition before adding generic cards. A container must have a grouping or state role.
- Build diagrams with editable shapes and connectors. Every directional connector needs an arrowhead, and connectors must terminate at node edges without crossing text.
- Choose chart types from the supplied data shape. Restyle default chart colors, frames, gridlines, labels, and legends to match the deck.
- Read each image asset before placing it. Cover a photo region without distortion; fit screenshots, diagrams, and logos without cropping important content. Protect text from busy images with a solid area or scrim.
- Use animation only when it improves sequence or emphasis. Every slide must still read correctly as a static frame, and animation must be checked in the target viewer.
- Keep one or two recurring visual motifs across the deck. Do not introduce a new decorative grammar on each page.

### Core operations

Confirm uncertain properties with help. These examples show the basic command shape:

```bash
# Blank slide with an explicit background
officecli add "$FILE" / --type slide --prop layout=blank --prop background=FFFFFF

# Named text shape
officecli add "$FILE" "/slide[1]" --type shape \
  --prop name=Title --prop text="Section title" \
  --prop x=2cm --prop y=1.4cm --prop width=29.8cm --prop height=2.2cm \
  --prop font="IBM Plex Sans SC" --prop size=36 --prop bold=true \
  --prop color=171717 --prop fill=none

# Picture
officecli add "$FILE" "/slide[1]" --type picture --prop src=hero.jpg \
  --prop x=18cm --prop y=4cm --prop width=13cm --prop height=10cm \
  --prop alt="Product image"

# Connector between named nodes
officecli add "$FILE" "/slide[2]" --type connector \
  --prop "from=/slide[2]/shape[@name=BoxA]" \
  --prop "to=/slide[2]/shape[@name=BoxB]" \
  --prop shape=elbow --prop color=333333 --prop tailEnd=triangle
```

Use `officecli help pptx add chart`, `officecli help pptx table`, and the element-specific help for charts, tables, groups, comments, hyperlinks, or animation.

## QA

Do not deliver after a structural check alone. Verify the file, the source transformation, and the visual result to the degree the request needs.

### 1. Structure

```bash
officecli validate "$FILE"
officecli view "$FILE" issues
```

Fix every schema, overflow, clipping, off-slide, or structural issue. Then inspect `view text` for leftover placeholders such as `xxxx`, `lorem`, `<TODO>`, or empty chart labels.

### 2. Narrative and source preservation

Compare the final slide map with the supplied material. Confirm that the page sequence is coherent and that every required source span, definition, constraint, qualification, number, label, and relationship remains present after conversion.

### 3. Visual review

Rendered slide views are expensive. Use `officecli view "$FILE" screenshot` only when a rendered view is necessary to meet the request or resolve a real layout uncertainty. Choose the least expensive view that answers the question:

```bash
officecli view "$FILE" screenshot --grid 3 -o overview.png
officecli view "$FILE" screenshot --page 1 -o slide-1.png
```

When visual inspection is warranted, check for:

- overlap, clipping, overflow, or shapes outside the canvas;
- narrow text boxes and broken line wrapping;
- weak contrast or dark-on-dark elements;
- stretched images, destructive crops, or text over busy imagery;
- missing arrowheads or connectors crossing text;
- inconsistent margins, gaps, baselines, and repeat-element sizes;
- headers, footers, page numbers, or footnotes colliding with body content;
- page skeletons that repeat without narrative reason;
- a slide order that differs from the checked page map.

Use `officecli view "$FILE" html` when it answers the question more cheaply. State any visual property that remains unverified. After a fix, rerun only the checks that establish whether the fix worked.

Finally, save the deck and open it in the target presentation viewer when one is available. OfficeCLI previews cannot prove target-viewer font substitution, chart rendering, animation, or import behavior.
