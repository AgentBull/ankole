# Financial & Chrono Charts (TradingView Lightweight Charts v5)

Use `AnkoleFinancialChart` (in React Applets) or `ankole-viz kline` (in Worker offline exports) whenever visualizing OHLC candlesticks, OHLC bars, intraday baseline spreads, synchronized volume/indicator sub-panes, trade execution markers, or treasury yield curves. General statistical grammar libraries do not collapse weekend/holiday trading gaps or synchronize multi-pane financial crosshairs cleanly.

## Time representation rules

Lightweight Charts distinguishes two strict time formats—never mix them inside one series:

1. **Business days (`'YYYY-MM-DD'`)**: Use for daily, weekly, or monthly bars so weekends and market holidays collapse without blank gaps.
2. **UTC Unix seconds (`number`, integer seconds—not milliseconds)**: Use for intraday bars (`1m`, `5m`, `1h`). Divide JavaScript millisecond timestamps by `1000` (`Math.floor(ms / 1000)`).

In Applets, use `recordsToFinancialSeries` from `@ankole/applet-sdk` to extract, validate, and sort Base records ascending by time before passing them to `AnkoleFinancialChart`:

```tsx
import { AnkoleFinancialChart } from '@ankole/uikit'
import { recordsToFinancialSeries, useRecords } from '@ankole/applet-sdk'

const { bars, volume } = recordsToFinancialSeries(records, {
  timeField: dateFieldId,
  timeUnit: 'business_day',
  openField: openId,
  highField: highId,
  lowField: lowId,
  closeField: closeId,
  volumeField: volumeId
})
```

## Directional color convention

- **Default (`marketConvention: 'intl'`)**: Green-up / red-down (`chart-up` for `close >= open`, `chart-down` for `close < open`). Use for US stocks, HK stocks, global indices, FX, commodities, bonds, and crypto.
- **Mainland China A-shares (`marketConvention: 'cn'`)**: Red-up / green-down. Set `marketConvention="cn"` (`--market cn` in `ankole-viz kline`) **only** when charting Mainland China A-share (`A股`, SSE/SZSE/BSE) equities or indices.

## Multi-pane indicators, markers, and yield curves

- **Overlays (pane `0`)**: Moving averages (`MA5`, `MA20`, `EMA`) and Bollinger bands share the main price scale.
- **Sub-panes (`paneIndex >= 1`)**: Volume (`HistogramSeries`), `MACD`, and `RSI` mount in dedicated lower panes with synchronized time-axis zoom and crosshair tracking.
- **Markers**: Annotate earnings releases, breakouts, or buy/sell signals via `markers` (`position: 'aboveBar' | 'belowBar'`, `shape: 'arrowUp' | 'arrowDown' | 'circle'`).
- **Yield curves (`mode: 'yield_curve'`)**: Plot maturity tenors in months (`1, 3, 6, 12, 24, 60, 120, 360`) on a proportional numeric horizon axis.
- **Attribution**: Keep TradingView attribution enabled (`attributionLogo: true`, the default) on every interactive and exported chart to satisfy Apache-2.0 notice requirements.

## Offline export (`ankole-viz kline`)

Because Lightweight Charts renders on HTML5 Canvas, `ankole-viz kline` exports high-DPI `.png` figures (`1920px` default print width):

```bash
ankole-viz kline \
  --spec '{"title":"CSI 300 daily price and volume","marketConvention":"cn","showVolume":true}' \
  --data ./csi300_ohlcv.csv \
  -o ./figures/csi300.png
```
