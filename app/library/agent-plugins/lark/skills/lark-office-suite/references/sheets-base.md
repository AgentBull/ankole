# Sheets and Base

## Lark Sheets

Use this service for a Lark spreadsheet URL or `spreadsheet_token`, not for a local Excel workbook; `lark-cli sheets --help` lists operations not shown here.

The bot-capable surface includes spreadsheets, sheets, values, ranges, batch reads/writes, formatting, merges, filters and filter views, protected ranges, conditional formats, data validation, charts, images, tables, find/replace, import/export tasks, and permission-sensitive metadata endpoints.

```bash
lark-cli sheets +workbook-info --url <spreadsheet_url> --as bot --format json
lark-cli sheets +cells-get --url <spreadsheet_url> --sheet-name Sheet1 --range A1:F50 --include value,formula,style --as bot --format json
lark-cli sheets +cells-set --url <spreadsheet_url> --sheet-name Sheet1 --range A1:B2 --cells @cells.json --as bot --format json
lark-cli sheets +table-put --spreadsheet-token <spreadsheet_token> --sheets @table.json --as bot --format json
lark-cli sheets spreadsheets get --help
lark-cli schema sheets.<resource>.<method>
```

For writes, read the target range first, preserve formulas and formats not named by the task, and batch adjacent changes. Do not export to `.xlsx` merely to edit data that the Sheets API can update directly.

## Lark Base

Base is a database-like cloud object with an `app_token`, tables, fields, views, records, roles, collaborators, forms, dashboards, and automations.

```bash
lark-cli base +field-list --base-token <app_token> --table-id <table_id> --as bot --format json
lark-cli base +record-list --base-token <app_token> --table-id <table_id> --limit 100 --as bot --format json
lark-cli base +record-upsert --base-token <app_token> --table-id <table_id> --json @record.json --as bot --format json
lark-cli base +record-upsert --base-token <app_token> --table-id <table_id> --record-id <record_id> --json @record.json --as bot --format json
lark-cli base <resource> <method> --help
lark-cli schema base.<resource>.<method>
```

`lark-cli base --help` lists operations not shown here. The typed surface can cover apps, tables, fields, views, records and batch records, roles and members, collaborators, forms, dashboards, workflows, and automation runs. Read the field schema before writing records; do not infer field types from rendered values. Use stable record IDs for updates and idempotent batch behavior where available.
