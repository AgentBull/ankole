---
title: OCR text recognition
description: Let an Agent read scanned PDFs, photos, screenshots, and receipts without a GPU or an external OCR service.
section: User guide
order: 25
---

Send a scanned document or image to an Agent and ask for the text that you need. Because Ankole bundles local OCR inside the Agent Computer Worker, you do not need to configure an external vision Provider, an API key, or a third-party OCR service.

For example, you can ask:

```text
Read all text in this screenshot and keep the original reading order.

Extract pages 2 to 5 from this scanned PDF. Mark any text that you cannot read with confidence.

Read this receipt and list the merchant, date, items, tax, and total.
```

## Advanced recognition on ordinary CPUs

Ankole runs the CPU-capable [PaddleOCR PP-OCRv6 medium](https://www.paddleocr.ai/latest/en/version3.x/algorithm/PP-OCRv6/PP-OCRv6.html) detection and recognition models—the accuracy-focused tier of the PP-OCRv6 family. In PaddleOCR's benchmarks, PP-OCRv6 medium improves text detection by 4.6% and text recognition by 5.1% over `PP-OCRv5_server`.

A single model covers 50 languages, including Simplified Chinese, Traditional Chinese, English, Japanese, and 46 Latin-script languages. Beyond flat document scans, it handles text in natural scenes such as screenshots, street signs, product labels, and digital displays.

Workers execute these models locally through OpenVINO on the CPU, delivering fast text recognition without a GPU. Because the model weights ship inside the Worker image, documents stay inside your deployment rather than going to an external OCR service, with no per-page fees.

## Ankole selects the accurate path

Because OCR estimates characters from pixels whereas native extraction reads exact character codes, Ankole automatically chooses the most accurate method for each file:

- **PDF with an embedded text layer:** the Agent extracts the original text directly.
- **Fully scanned PDF:** the Agent runs OCR across every page.
- **Mixed PDF:** the Agent extracts embedded text where available and runs OCR only on scanned pages.
- **DOCX, PPTX, and XLSX files:** the Agent parses the native document structure rather than rasterizing pages into images.

You never have to specify which extraction method to use—simply attach the original file and describe the output you want.

## What the Agent can return

From the recognized text, the Agent can return raw transcripts, cleaned prose, summaries, or structured fields. Because the OCR engine also reports bounding-box coordinates and per-line confidence scores, the Agent can preserve multi-column reading order and flag low-confidence passages on degraded scans.

For best accuracy, send a sharp, upright image at full resolution—prefer the original file over a compressed chat screenshot when dealing with fine print. You can also ask the Agent to highlight uncertain lines explicitly instead of guessing.

## Limits

- Scripts outside the 50-language model—including Korean, Arabic, Cyrillic, and Thai—are not supported.
- Cursive handwriting, mathematical formulas, complex tables, curved text, and blurry or heavily skewed photos can reduce recognition accuracy. Tables are extracted as positioned text lines rather than a reconstructed table grid.
- Running OCR extracts text for the Agent to use, but does not embed a searchable text layer back into the source PDF.

The `ocr` Skill is enabled by default. If an Agent reports that OCR is unavailable, verify that its Worker runs a current Worker image and that the `ocr` Skill is enabled in **Agent Library**.
