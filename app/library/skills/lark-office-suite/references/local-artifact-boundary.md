# Lark cloud versus local Office artifacts

Choose by resource ownership, not by the word "document" or "spreadsheet".

| Input or desired result | Owning skill |
|---|---|
| Lark Docs/Wiki URL, doc token, cloud document body | `lark-office-suite` |
| Lark Sheets URL or spreadsheet token | `lark-office-suite` |
| Lark Base URL or app token | `lark-office-suite` |
| Local `.docx` file | `docx` |
| Local `.xlsx`, `.xls`, `.csv`, or `.tsv` file | `xlsx` |
| Lark Slides or Whiteboard URL/token | `lark-office-suite` |

For cloud-to-local export, first use Drive or the owning Lark service to write a relative local file, then use `docx` or `xlsx` only if the user asked to inspect or edit that file. For local-to-cloud import, finish and validate the local artifact first, then use Drive import/upload with a relative path.

Do not use OfficeCLI against a Lark URL. Do not rebuild a Lark document through local `.docx` round-tripping when Docs can edit it directly. Do not call Lark Sheets for a local workbook that has no Lark cloud token.
