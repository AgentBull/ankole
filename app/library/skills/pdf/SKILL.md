---
name: pdf
description: "Create, check, edit, and read PDF files. Use when a deliverable must ship as a PDF, when a generated PDF needs verification, when an existing PDF needs a text correction, or when an inbound PDF needs its text extracted or its scanned pages triaged for OCR."
default_enabled: true
category: productivity
tags: [PDF, Documents, Publishing, Productivity]
version: 2.1.0
ankole-runtime: background_job
license: MIT
platforms: [linux]
---

# PDF

The Agent Computer image installs Pandoc, two PDF engines, Poppler, QPDF,
pdf-inspector (`detect-pdf`, `pdf2md`), and `nano-pdf`. This Skill owns how a
PDF is read, made, checked, and corrected.

> **Important:** If the human has already provided a brand palette or template, match that first. Otherwise, use `design-md` skills and use it as the design reference.

## Read

Classify before extracting. `detect-pdf` samples content streams in
milliseconds and reports whether a text layer exists at all:

```bash
detect-pdf in.pdf --json   # pdf_type, confidence, ocr_recommended, pages_needing_ocr
```

- `text_based`: extract locally with `pdf2md in.pdf`. It returns structured
  Markdown with headings, lists, tables, and multi-column reading order.
  It owns PDF reading; do not read PDFs through `pdftotext` or `markitdown`.
- `scanned` or `image_based`: no text layer exists, and `pdf2md` fails with
  a clear error. Route the file to the `ocr` Skill.
- `mixed`: extract the text pages with `pdf2md in.pdf --select-pages 1,3-5`,
  then hand only the `pages_needing_ocr` list to the `ocr` Skill. OCR costs
  seconds per page; never send pages that extraction already covered.

When `ocr_recommended` is true, trust it over the type label. Treat low
`confidence` as scan-suspect even for `text_based`: extract one page and
check the output before trusting the whole file.

## Create

Always produce the PDF with Pandoc from an authoritative source document. Do not
lay out pages with a plotting library such as Matplotlib: it cannot reflow text,
so it overlaps content without an error.

Pick the engine that fits the document. Both are installed, and each one takes a
different styling language:

| Engine | Command | Styling | Fits |
| --- | --- | --- | --- |
| WeasyPrint | `pandoc in.md -o out.pdf --pdf-engine=weasyprint --css print.css` | Print CSS, `@page` rules | A design system already written as CSS, dense tables, one-page-per-section briefs |
| Typst | `pandoc in.md -o out.pdf --pdf-engine=typst -V mainfont="IBM Plex Sans SC"` | Typst template | Fast rebuilds, long structured reports, math |

No LaTeX engine is installed. For citations use Pandoc's own `--citeproc`, which
works with both engines. Do not install a TeX distribution inside a Job.

The image installs three text families, and `design-md` owns which one to use:
`IBM Plex Sans SC` for text, `IBMPlexMonoSCHalf` for code, and `寒蝉锦书宋`
(ChillJinshuSong) for serif. Sans and mono carry weights 300 to 700 including
SemiBold 600; the serif has no SemiBold, so 600 resolves to Bold there. Fluent
Emoji Color sits behind all three for emoji. Name the family explicitly, because
an engine default can silently drop CJK glyphs. WeasyPrint accepts the ASCII
alias `ChillJinshuSong`; Typst matches the family name inside the font file, so
it needs `寒蝉锦书宋`.

For HTML input, convert with `pandoc --standalone --from markdown+raw_html --to
html5 --css <stylesheet>` first, then print that HTML through the same engine.

## Check

A generated PDF needs a check, but not a visual one. Reading page images costs
far more context than it returns and it forces conversation compaction. Run
these instead:

```bash
pdfinfo report.pdf                       # page count, page size, embedded fonts
qpdf --check report.pdf                  # file structure
pdftotext -layout report.pdf out.txt     # text must agree with the source document
tr -cd '\f' < out.txt | wc -c            # form feeds must equal the page count
pdftotext -bbox-layout report.pdf -      # text box geometry
```

The geometry output carries every text box with its coordinates. Overlapping
boxes mean overlapping content, and a box outside the page margin means clipped
content. Both are the defects a visual pass looks for, and this finds them
without an image.

Render a page image only for a page that the geometry check reports, look at
that one page, and record what it shows.

## Edit

`nano-pdf` corrects text in an existing PDF from a natural-language
instruction. Use it for a typo, a title, or a date, not for layout work:
rebuild the PDF from its source instead.

```bash
nano-pdf edit report.pdf 3 "Update the date from January to February 2026"
```

Page numbers can be 0-based or 1-based depending on the version. If the edit
lands on the wrong page, retry with ±1. The tool calls an LLM, so it needs its
own API key; check `nano-pdf --help`.
