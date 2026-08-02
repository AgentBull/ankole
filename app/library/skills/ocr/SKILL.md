---
name: ocr
description: "Recognize text in images with the local PP-OCRv6 model: photos, screenshots, scanned page images, receipts, and whiteboard shots. Use when text must be read out of pixels. For any PDF, even a fully scanned one, start with the pdf Skill; its triage hands scanned pages here itself."
default_enabled: true
category: productivity
tags: [OCR, Documents, Images, PDF, Text-Extraction, Productivity]
version: 1.0.0
ankole-runtime: background_job
license: MIT
platforms: [linux]
metadata:
  implementation: rapidocr-openvino
  models: PP-OCRv6 medium det/rec
  upstream: https://github.com/RapidAI/RapidOCR
  related_skills: [pdf, docx, pptx, xlsx]
---

# OCR

This Skill reads **text out of pixels**: photos, screenshots, scans,
whiteboard shots, receipts, and PDF pages that carry no machine-readable
text. The Agent Computer image installs RapidOCR with the PP-OCRv6 medium
detection and recognition models on the OpenVINO CPU runtime, so recognition
runs locally: no network call, no API key, no cost per page.

Do not OCR a document that carries real text. Extraction is exact and
instant; recognition is approximate and costs seconds per page:

- DOCX, PPTX, XLSX: parse the real document tree with `python-docx`,
  `python-pptx`, or `openpyxl` — the `docx`, `pptx`, and `xlsx` Skills own
  those formats.
- A PDF with a text layer: `pdf2md in.pdf` extracts it exactly — the `pdf`
  Skill owns PDF reading.

## Images

An image is the plain case: no exact text source exists, so recognize
directly.

```bash
python scripts/ocr.py photo.jpg receipt.png       # plain text per input
python scripts/ocr.py screenshot.png --json       # per-line text, score, quad box
```

Resolve `scripts/ocr.py` from this Skill's own directory.

## PDFs

The `pdf` Skill's Read section owns PDF triage: it decides which pages carry
a text layer and which need recognition. A PDF reaches this Skill in one of
three shapes:

- The whole file, classified `scanned` or `image_based`: recognize every
  page.
- A `pages_needing_ocr` list from a `mixed` file: pass it to `--pages`. The
  text pages are already extracted; do not touch them again.
- A bare, untriaged PDF: do the `pdf` Skill's Read triage first. A text
  layer beats recognition, and the triage names the pages that need it.

```bash
python scripts/ocr.py in.pdf                 # scanned file, every page
python scripts/ocr.py in.pdf --pages 2,6     # only the listed pages
```

## Cost And Flags

The models load once per process and take seconds; each page then costs
roughly one to two seconds of CPU. Pass every input in one invocation
instead of looping shell calls. The script accepts `--help` for full usage.

- `--pages` limits a PDF to the listed pages, as `2,5-7`.
- `--dpi` (default 200) sets PDF rasterization resolution. Use 300 when the
  source has small print; cost grows with the square of the value.
- `--json` adds a confidence score and a quad box per line.

## Read The Scores

Recognition output is a claim, not a fact. Before trusting a poor scan, run
`--json` and read the scores: a page whose lines sit under about 0.6 means a
bad rasterization, a skewed photo, or an unsupported script — not usable
text. Retry a photo after cropping or rotating with ImageMagick, and retry
small print at `--dpi 300`, before concluding the document is unreadable.

## Limits

- One model covers 50 languages: Simplified and Traditional Chinese, English,
  Japanese, and the Latin-script European languages. Korean, Arabic, Cyrillic,
  Thai, and other scripts are not covered. When a document falls outside
  coverage, do not deliver garbage text; tell the human:
  > "This document appears to be in [script], which the local OCR model does
  > not cover. I can work with a text-bearing version of the file, or you can
  > tell me how you want the original handled."
- Output is text lines in reading order with positions. Tables come back as
  positioned lines, not table markup; formulas and handwriting degrade.
- The Skill reads text out of a document. It does not write a text layer back
  into a PDF, so it cannot make a PDF searchable.
