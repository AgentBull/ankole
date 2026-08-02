---
title: OCR text recognition
description: Let an Agent read scanned PDFs, photos, screenshots, and receipts without a GPU or an external OCR service.
section: User guide
order: 25
---

Send the file to an Agent and ask for the text that you need. Ankole includes OCR in the Agent Computer Worker, so you do not need to configure a model Provider, an API key, or a separate OCR service.

For example, you can ask:

```text
Read all text in this screenshot and keep the original reading order.

Extract pages 2 to 5 from this scanned PDF. Mark any text that you cannot read with confidence.

Read this receipt and list the merchant, date, items, tax, and total.
```

## Advanced recognition on ordinary CPUs

Ankole uses the state-of-the-art, CPU-capable [PaddleOCR PP-OCRv6 medium](https://www.paddleocr.ai/latest/en/version3.x/algorithm/PP-OCRv6/PP-OCRv6.html) detection and recognition models. The medium tier is the accuracy-focused model in the PP-OCRv6 family. In PaddleOCR's evaluation, it improves text detection by 4.6% and text recognition by 5.1% over PP-OCRv5_server.

One model covers 50 languages, including Simplified Chinese, Traditional Chinese, English, Japanese, and 46 Latin-script languages. It also handles text in document scans and natural scenes, such as screenshots, signs, product labels, and digital displays.

Ankole runs the models locally through an OpenVINO-optimized CPU inference path. This gives a normal Worker fast local recognition without a GPU. The models are already in the Worker image, so a document does not go to an external OCR service and there is no fee for each page.

## Ankole selects the accurate path

OCR estimates text from pixels, but normal extraction reads the original characters. Ankole uses the more accurate path when it is available:

- For a PDF with a text layer, the Agent extracts the original text.
- For a fully scanned PDF, it recognizes every page.
- For a mixed PDF, it uses OCR only on the pages that need it and extracts the other pages directly.
- For DOCX, PPTX, and XLSX files, the Agent reads the document structure instead of treating each page as an image.

You do not need to select this path yourself. Send the original file when possible and state the result that you want.

## What the Agent can return

The Agent can return plain text, a cleaned transcript, a summary, or structured facts from the recognized text. OCR also provides the position and confidence of each line. This helps the Agent preserve reading order and warn you when a poor scan is not reliable enough.

For the best result, use a clear, upright image with enough resolution. If the source has small print, send the original file instead of a compressed screenshot. You can also ask the Agent to report uncertain lines instead of silently guessing.

## Limits

- Korean, Arabic, Cyrillic, Thai, and other scripts outside the 50-language model are not covered.
- Handwriting, formulas, complex tables, curved text, and blurred or strongly skewed photos can lose accuracy. Tables return as positioned text lines, not as guaranteed table structure.
- OCR reads the content but does not add a searchable text layer to the original PDF.

The `ocr` Skill is enabled by default. If an Agent says that OCR is unavailable, confirm that the Agent uses a current Worker image and that the Skill is enabled in **Agent Library**.
