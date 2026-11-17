# gridcraft-xlsx 0.13.0

Source: the `gridcraft-xlsx` crate at commit
`68a4b1a1c3684fa17553ecb2a1f088c75f6a3567` from
https://github.com/storytold/gridcraft.
The MIT and Apache-2.0 licenses are included alongside the upstream source.
Upstream unit test modules and fixtures are omitted from this patched copy.

Ankole preserves positive OOXML `<xdr:cNvPr id>` object identifiers across
spreadsheet read/write round-trips:

- `src/read.rs` tracks workbook-wide `used_ids` alongside `next_id` (starting at
  `1`). `Ctx::claim_object_id` reserves an explicit positive `<xdr:cNvPr id>`
  into `used_ids` without advancing `next_id` (returning `0` when missing or
  colliding), and `assign_missing_object_ids` runs once every worksheet has been
  parsed to allocate fresh workbook-unique IDs from `next_id` for tables and any
  drawing objects still carrying `0`.
- `src/sheet_read.rs` leaves imported `Table.id` at `0` during worksheet parsing
  so tables receive non-colliding model IDs in the post-sheet pass rather than
  consuming IDs used by drawing objects on subsequent sheets.
- `src/drawing.rs` reads `<xdr:cNvPr id>` for pictures (`nvPicPr`), charts and
  ChartEx frames (`nvGraphicFramePr`), and shapes/connectors (`nvSpPr`,
  `nvCxnSpPr`) through `claim_object_id`, and reserves all distinct positive
  object IDs up front in `write_drawing` before assigning fallback IDs within a
  drawing part.

`ankole_spreadsheet`'s round-trip and rebase suites exercise floating object ID
stability across imports and edits.
