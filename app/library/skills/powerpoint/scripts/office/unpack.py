"""Unpack a DOCX, PPTX, or XLSX file into a directory and pretty-print XML.

Usage:
    python scripts/office/unpack.py input.pptx unpacked/
"""

import argparse
import shutil
import zipfile
from pathlib import Path

import defusedxml.minidom


def unpack(input_file: str, output_directory: str) -> None:
    input_path = Path(input_file)
    output_dir = Path(output_directory)
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)

    with zipfile.ZipFile(input_path, "r") as zf:
        zf.extractall(output_dir)

    for pattern in ("*.xml", "*.rels"):
        for xml_file in output_dir.rglob(pattern):
            try:
                dom = defusedxml.minidom.parse(str(xml_file))
                xml_file.write_bytes(dom.toprettyxml(indent="  ", encoding="UTF-8"))
            except Exception:
                # Keep non-standard XML parts intact; pack.py will surface hard failures.
                pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Unpack an Office Open XML file")
    parser.add_argument("input_file")
    parser.add_argument("output_directory")
    args = parser.parse_args()
    unpack(args.input_file, args.output_directory)
