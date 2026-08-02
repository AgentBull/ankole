#!/usr/bin/env python3
"""OCR images and scanned PDF pages with PP-OCRv6 medium on OpenVINO.

Inputs are image files or PDFs. PDF pages rasterize through pdftoppm
before recognition. Output is plain text per page on stdout, or
line-level JSON with --json. Pass every input in one invocation: the
models load once per process.
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

IMAGE_SUFFIXES = {".bmp", ".jpeg", ".jpg", ".png", ".tif", ".tiff", ".webp"}


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


def rasterize(pdf_path: Path, pages: list[int] | None, dpi: int, out_dir: Path) -> list[tuple[int, Path]]:
    """Renders selected PDF pages to PNG files and returns (page, path) pairs.

    Renders into a fresh subdirectory with a fixed prefix, so a source file
    name never reaches the result glob.
    """
    render_dir = Path(tempfile.mkdtemp(prefix="pages-", dir=out_dir))
    if pages:
        rendered = []
        for page in pages:
            target = render_dir / f"p{page}"
            subprocess.run(
                ["pdftoppm", "-png", "-r", str(dpi), "-singlefile",
                 "-f", str(page), "-l", str(page), str(pdf_path), str(target)],
                check=True,
            )
            rendered.append((page, target.with_suffix(".png")))
        return rendered
    prefix = render_dir / "page"
    subprocess.run(["pdftoppm", "-png", "-r", str(dpi), str(pdf_path), str(prefix)], check=True)
    produced = sorted(render_dir.glob("page-*.png"))
    return [(int(path.stem.rsplit("-", 1)[1]), path) for path in produced]


def build_engine():
    from rapidocr import EngineType, ModelType, OCRVersion, RapidOCR

    return RapidOCR(
        params={
            "Det.engine_type": EngineType.OPENVINO,
            "Det.ocr_version": OCRVersion.PPOCRV6,
            "Det.model_type": ModelType.MEDIUM,
            "Cls.engine_type": EngineType.OPENVINO,
            "Rec.engine_type": EngineType.OPENVINO,
            "Rec.ocr_version": OCRVersion.PPOCRV6,
            "Rec.model_type": ModelType.MEDIUM,
        }
    )


def recognize(engine, image_path: Path) -> list[dict]:
    result = engine(str(image_path), use_cls=True)
    lines = []
    for index, text in enumerate(result.txts or []):
        score = float(result.scores[index]) if result.scores is not None else None
        box = result.boxes[index].astype(int).tolist() if result.boxes is not None else None
        lines.append({"text": text, "score": round(score, 3) if score is not None else None, "box": box})
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description="OCR images and scanned PDFs with PP-OCRv6.")
    parser.add_argument("inputs", nargs="+", type=Path, help="Image or PDF files.")
    parser.add_argument("--pages", help="PDF page selection such as 2,5-7. Applies to every PDF input.")
    parser.add_argument("--dpi", type=int, default=200, help="PDF rasterization resolution (default 200).")
    parser.add_argument("--json", action="store_true", help="Emit line-level JSON with scores and boxes.")
    args = parser.parse_intermixed_args()

    try:
        pages = parse_pages(args.pages) if args.pages else None
    except ValueError as error:
        print(error, file=sys.stderr)
        return 2
    for path in args.inputs:
        if not path.is_file():
            print(f"not a file: {path}", file=sys.stderr)
            return 2
        if path.suffix.lower() not in IMAGE_SUFFIXES | {".pdf"}:
            print(f"unsupported input type: {path}", file=sys.stderr)
            return 2

    engine = build_engine()
    documents = []
    with tempfile.TemporaryDirectory(prefix="ocr-") as scratch:
        scratch_dir = Path(scratch)
        for path in args.inputs:
            if path.suffix.lower() == ".pdf":
                for page, image_path in rasterize(path, pages, args.dpi, scratch_dir):
                    documents.append({"source": str(path), "page": page, "lines": recognize(engine, image_path)})
            else:
                documents.append({"source": str(path), "page": None, "lines": recognize(engine, path)})

    if args.json:
        json.dump(documents, sys.stdout, ensure_ascii=False)
        print()
        return 0

    multi = len(documents) > 1
    for document in documents:
        if multi:
            label = document["source"] if document["page"] is None else f"{document['source']} page {document['page']}"
            print(f"--- {label} ---")
        if document["lines"]:
            print("\n".join(line["text"] for line in document["lines"]))
        else:
            print("(no text detected)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
