# Statistical & Multi-Dimensional Charts (AntV G2 v5)

## Choosing the chart type

| Question | Chart type | Notes |
| --- | --- | --- |
| Compare discrete categories | `column` (<=8 short labels) or `bar` (long labels or >8 items) | Always start quantitative bar/column axes at `0`. |
| Track change over ordered time | `line` or `area` | Enable `fill_missing_buckets` (`true` by default): `count` and `sum` fill `0`; `avg`, `min`, `max`, and `count_distinct` fill `null` so gaps break cleanly instead of interpolating fake slopes. |
| Compare two metrics with distinct units | `combo` (columns + secondary-axis line) | Put primary volume/amount on left axis and rate/margin in `encoding.secondary_metric_aliases`. |
| Show part-to-whole composition | `donut` or `pie` (<=6 slices), `column` with `stack_mode: "percent"` (over time) | When any slice or series contains negative values, use `stacked` or `grouped` instead of `percent`. |
| Track stage conversion | `funnel` | Order stages in pipeline sequence. |
| Examine correlation or outliers | `scatter` | Queries up to `1,000` records ordered by view `sort` + `id ASC` (deterministic prefix, not random sampling). |
| Show distribution or quantiles (Applet / CLI) | `histogram`, `boxplot` | Compute or pass raw observations in an Applet (`AnkoleChart`) or `ankole-viz chart`. |
| Show hierarchy or multi-stage flow (Applet / CLI) | `treemap`, `sunburst`, `sankey` | Pass `nodes`/`links` or hierarchical `value` rows to `AnkoleChart` or `ankole-viz chart`. |

## Base `chart` view & Doc `<embed>` schema

Every field reference inside `ChartViewSpec` uses `{ "field_id": "<uuid>" }` from `ankole-pod base.schema`:

```json
{
  "chart": {
    "chart_type": "column",
    "query": {
      "group_by": [
        { "field_id": "019a0000-0000-7000-8000-000000000001", "bucket": "month" },
        { "field_id": "019a0000-0000-7000-8000-000000000002" }
      ],
      "metrics": [
        { "operation": "sum", "field_id": "019a0000-0000-7000-8000-000000000003", "alias": "revenue" }
      ],
      "order_by": [{ "group_index": 0, "direction": "asc" }],
      "top_n": { "limit": 5, "include_other": true, "target_group_index": 1 },
      "omit_empty": false
    },
    "display": {
      "stack_mode": "stacked",
      "cumulative": false,
      "fill_missing_buckets": true,
      "reference_lines": [{ "value": 100000, "label": "Monthly target" }],
      "caption": "Monthly revenue by top 5 product lines"
    }
  }
}
```

- `cumulative: true` applies only to additive metrics (`count` and `sum`), never to `avg`, `min`, `max`, or `count_distinct`.
- `top_n` folds tail keys into `"Other"` inside PostgreSQL before aggregation, so `avg` and `count_distinct` on `"Other"` remain exact and multi-select records carrying multiple tail tags count once.

## Applet usage (`@ankole/uikit`)

Import `AnkoleChart` from the root `@ankole/uikit` module:

```tsx
import { AnkoleChart } from '@ankole/uikit'
import { densifyTimeBuckets, useAggregate, usePod } from '@ankole/applet-sdk'
```

## Offline export (`ankole-viz chart`)

```bash
ankole-viz chart \
  --spec '{"chartType":"column","title":"Quarterly revenue dropped 8% in Q3","xField":"quarter","yField":"revenue","seriesField":"region"}' \
  --data ./revenue.csv \
  --pdf-safe \
  -o ./figures/revenue.svg
```
