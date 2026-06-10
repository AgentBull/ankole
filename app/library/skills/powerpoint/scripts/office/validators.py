"""Minimal Office validators used by pack.py.

The full PowerPoint QA loop renders the packed deck and inspects slide images.
These classes keep pack.py import-compatible and perform a basic XML parse pass
without trying to enforce the full OOXML schema.
"""

from pathlib import Path

import defusedxml.minidom


class _XmlParseValidator:
    def __init__(self, unpacked_dir: Path, _original_file: Path, **_kwargs):
        self.unpacked_dir = Path(unpacked_dir)

    def repair(self) -> int:
        return 0

    def validate(self) -> bool:
        for pattern in ("*.xml", "*.rels"):
            for xml_file in self.unpacked_dir.rglob(pattern):
                defusedxml.minidom.parse(str(xml_file))
        return True


class DOCXSchemaValidator(_XmlParseValidator):
    pass


class PPTXSchemaValidator(_XmlParseValidator):
    pass


class RedliningValidator(_XmlParseValidator):
    pass
