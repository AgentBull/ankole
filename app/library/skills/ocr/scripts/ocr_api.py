#!/usr/bin/env python3
"""OCR an image or a PDF through the AIGateway `/ocr` endpoint.

The endpoint returns Markdown per page. It reads a PDF when the space has
an OCR model bound; without one, a language model that accepts images reads
one image. Output is the Markdown of each page on stdout, or the endpoint's
JSON with --json.
"""

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

CONTENT_TYPES = {
    ".jpeg": "image/jpeg",
    ".jpg": "image/jpeg",
    ".pdf": "application/pdf",
    ".png": "image/png",
    ".webp": "image/webp",
}


def parse_pages(spec: str) -> list[int]:
    """Expands a page selection such as "2,5-7" into sorted page numbers."""
    pages: set[int] = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            low, high = part.split("-", 1)
            pages.update(range(int(low), int(high) + 1))
        else:
            pages.add(int(part))
    if not pages or min(pages) < 1:
        raise ValueError(f"invalid page selection: {spec!r}")
    return sorted(pages)


def request_ocr(path: Path, pages: list[int] | None) -> dict:
    """Sends one document and returns the endpoint's response body."""
    body = {
        "model": "ocr.default",
        "document": {
            "content_type": CONTENT_TYPES[path.suffix.lower()],
            "base64": base64.b64encode(path.read_bytes()).decode("ascii"),
        },
    }
    if pages:
        # The endpoint numbers pages from 0.
        body["pages"] = [page - 1 for page in pages]

    token = Path(os.environ["ANKOLE_RUNTIME_AI_GATEWAY_TOKEN_FILE"]).read_text().strip()
    request = urllib.request.Request(
        os.environ["ANKOLE_RUNTIME_AI_GATEWAY_URL"].rstrip("/") + "/ocr",
        data=json.dumps(body).encode("utf-8"),
        headers={"authorization": f"Bearer {token}", "content-type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=600) as response:
        return json.load(response)


def main() -> int:
    parser = argparse.ArgumentParser(description="OCR an image or a PDF through the AIGateway.")
    parser.add_argument("input", type=Path, help="A PDF, PNG, JPEG, or WebP file.")
    parser.add_argument("--pages", help="PDF page selection such as 2,5-7, at most 100 pages.")
    parser.add_argument("--json", action="store_true", help="Emit the endpoint's JSON response.")
    args = parser.parse_intermixed_args()

    if not args.input.is_file():
        print(f"not a file: {args.input}", file=sys.stderr)
        return 2
    if args.input.suffix.lower() not in CONTENT_TYPES:
        print(f"unsupported input type: {args.input}", file=sys.stderr)
        return 2
    try:
        pages = parse_pages(args.pages) if args.pages else None
    except ValueError as error:
        print(error, file=sys.stderr)
        return 2

    try:
        result = request_ocr(args.input, pages)
    except urllib.error.HTTPError as error:
        # The endpoint says which field is at fault and why.
        print(f"OCR request failed with HTTP {error.code}: {error.read().decode('utf-8', 'replace')}", file=sys.stderr)
        return 1
    except (KeyError, OSError) as error:
        print(f"OCR request failed: {error!r}", file=sys.stderr)
        return 1

    if args.json:
        json.dump(result, sys.stdout, ensure_ascii=False)
        print()
        return 0

    multi = len(result["pages"]) > 1
    for page in result["pages"]:
        if multi:
            print(f"--- page {page['index'] + 1} ---")
        print(page["markdown"] or "(no text detected)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
