---
name: ocr
description: "Recognize text in images and scanned PDFs: screenshots, scanned copy, receipts, etc., with the local OCR engine or through the OCR API. Use when text must be read out of pixels. For any PDF, start with the pdf Skill."
default_enabled: true
category: productivity
tags: [OCR, Documents, Images, PDF, Text-Extraction, Productivity]
version: 1.1.0
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
text. It offers two tools:

- `scripts/ocr.py` runs the local engine. The Agent Computer image installs
  RapidOCR with the PP-OCRv6 medium detection and recognition models on the
  OpenVINO CPU runtime, so recognition runs locally: no network call, no API
  key, no cost per page.
- `scripts/ocr_api.py` sends the file to the AIGateway `/ocr` endpoint,
  which answers with Markdown per page. See [OCR API](#ocr-api).

Which tool to use, or whether to read an image with your own vision, is your
call. The sections below say what each tool reads, returns, and costs.

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

`ocr.py` selects the input type from the file-name suffix. Before the first
OCR call, make sure each image has a supported suffix. If an image has no
suffix, run `file --brief --mime-type -- INPUT`, copy it to a temporary path
with the suffix that matches the reported type (for example, `.jpg` for
`image/jpeg`), and pass the copy to `ocr.py`. Keep the original file unchanged.

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

## OCR API

`ocr_api.py` sends one image or PDF to the AIGateway `/ocr` endpoint and
prints the Markdown of each page. It needs no setup: the runtime provides
the endpoint's address in `ANKOLE_RUNTIME_AI_GATEWAY_URL` and the Agent's
key in the file that `ANKOLE_RUNTIME_AI_GATEWAY_TOKEN_FILE` names.

```bash
python scripts/ocr_api.py scan.pdf                 # every page
python scripts/ocr_api.py scan.pdf --pages 2,6     # only the listed pages, at most 100
python scripts/ocr_api.py photo.jpg --json         # the endpoint's JSON: model, pages, usage
```

Who reads the file depends on how the space is configured:

- With an OCR model bound, that model reads the file: a PDF of up to 50 MiB,
  or a PNG, JPEG, or WebP image of up to 20 MiB. The scripts and layouts
  that it reads are the model's own, not the local engine's. Its provider
  bills the space for each page.
- Without an OCR model, a language model that accepts images reads one
  image, and the endpoint rejects a PDF with an error that says so. That
  request counts against the Agent's token quota like any other model call.

The answer is Markdown, so headings and tables keep their structure where
the model recognizes them. With `--json`, the `model` field names who read
the file and `usage` counts the pages. When the endpoint rejects a request,
the script prints the endpoint's error, which names the field at fault, and
exits 1.

## Cost And Flags Of The Local Engine

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

- The local model covers 50 languages: Simplified and Traditional Chinese,
  English, Japanese, and the Latin-script European languages. Korean, Arabic,
  Cyrillic, Thai, and other scripts are not covered: for them the local
  engine returns garbage text with low scores. The OCR API does not share
  this limit; its coverage is that of the model that answers.
- The local engine's output is text lines in reading order with positions.
  Tables come back as positioned lines, not table markup; formulas and
  handwriting degrade.
- The Skill reads text out of a document. It does not write a text layer back
  into a PDF, so it cannot make a PDF searchable.
