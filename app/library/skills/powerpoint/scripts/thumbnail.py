"""Create a thumbnail contact sheet for a PPTX via LibreOffice + Poppler.

Usage:
    python scripts/thumbnail.py input.pptx [output_prefix] [--cols N]
"""

import argparse
import math
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw


def render_contact_sheet(input_file: str, output_prefix: str = "thumbnails", cols: int = 3) -> Path:
    input_path = Path(input_file).resolve()
    output_path = Path(f"{output_prefix}.jpg")
    with tempfile.TemporaryDirectory() as temp:
        temp_dir = Path(temp)
        subprocess.check_call(
            [
                "python",
                str(Path(__file__).parent / "office" / "soffice.py"),
                "--headless",
                "--convert-to",
                "pdf",
                "--outdir",
                str(temp_dir),
                str(input_path),
            ]
        )
        pdf = temp_dir / f"{input_path.stem}.pdf"
        subprocess.check_call(["pdftoppm", "-jpeg", "-r", "72", str(pdf), str(temp_dir / "slide")])
        slides = sorted(temp_dir.glob("slide-*.jpg"))
        if not slides:
            raise RuntimeError("no slide thumbnails were produced")

        images = [Image.open(slide).convert("RGB") for slide in slides]
        thumb_w = 320
        label_h = 28
        gap = 16
        resized = []
        for image in images:
            ratio = thumb_w / image.width
            resized.append(image.resize((thumb_w, max(1, int(image.height * ratio)))))

        rows = math.ceil(len(resized) / cols)
        cell_h = max(image.height for image in resized) + label_h
        sheet = Image.new("RGB", (cols * thumb_w + (cols + 1) * gap, rows * cell_h + (rows + 1) * gap), "white")
        draw = ImageDraw.Draw(sheet)
        for index, image in enumerate(resized):
            row, col = divmod(index, cols)
            x = gap + col * (thumb_w + gap)
            y = gap + row * (cell_h + gap)
            sheet.paste(image, (x, y + label_h))
            draw.text((x, y), f"slide {index + 1}", fill=(0, 0, 0))

        sheet.save(output_path, quality=90)
        return output_path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Create PPTX thumbnail contact sheet")
    parser.add_argument("input_file")
    parser.add_argument("output_prefix", nargs="?", default="thumbnails")
    parser.add_argument("--cols", type=int, default=3)
    args = parser.parse_args()
    print(render_contact_sheet(args.input_file, args.output_prefix, args.cols))
