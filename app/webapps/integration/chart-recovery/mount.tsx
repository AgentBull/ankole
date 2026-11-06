import { useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { AnkoleChart, AnkoleInfographic, type AnkoleChartHandle, type StatisticalChartType } from '@ankole/uikit'

const INTERACTIVE_ROWS = [
  { x: '进行中', series: '产品', y: 5, __formattedY: '5', __groupIndex: 0 },
  { x: '已完成', series: '研发', y: 3, __formattedY: '3', __groupIndex: 1 }
]

function InfographicRecovery() {
  const [source, setSource] = useState('infographic missing-template\ndata\n  title Broken')
  const [chartType, setChartType] = useState<StatisticalChartType>('pie')
  const [clickedGroup, setClickedGroup] = useState<string>('none')
  const [exportedInfo, setExportedInfo] = useState<string>('')
  const chartHandleRef = useRef<AnkoleChartHandle | null>(null)

  return (
    <main style={{ padding: 16 }}>
      <label>
        Diagram source
        <textarea value={source} onChange={event => setSource(event.target.value)} />
      </label>
      <AnkoleInfographic source={source} eager />
      <AnkoleChart
        ariaLabel="Sales chart"
        eager
        spec={{ type: 'column', renderer: 'svg', data: [{ x: 'Sales', y: 12 }], xField: 'x', yField: 'y' }}
      />

      <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
        {(['pie', 'donut', 'column', 'line', 'funnel', 'sunburst'] as const).map(t => (
          <button key={t} type="button" onClick={() => setChartType(t)}>
            Switch {t}
          </button>
        ))}
        <button
          type="button"
          onClick={() => {
            const next = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark'
            document.documentElement.setAttribute('data-theme', next)
          }}>
          Toggle theme
        </button>
        <button
          type="button"
          onClick={async () => {
            const svg = await chartHandleRef.current!.exportSVG()
            const png = await chartHandleRef.current!.exportPNG()
            setExportedInfo(`svg:${svg.length}:png:${png.startsWith('data:image/png;base64,')}`)
          }}>
          Probe export
        </button>
      </div>
      <div data-testid="clicked-group">{clickedGroup}</div>
      <div data-testid="exported-info">{exportedInfo}</div>

      <AnkoleChart
        ref={chartHandleRef}
        ariaLabel="Interactive status chart"
        eager
        allowExport
        spec={{
          type: chartType,
          data: INTERACTIVE_ROWS,
          xField: 'x',
          yField: 'y',
          valueField: 'y',
          ...(chartType === 'column' ? { seriesField: 'series', referenceLines: [{ value: 4, label: '目标' }] } : {}),
          ...(chartType === 'donut' ? { donutCenterLabel: { value: '8', title: '总计' } } : {}),
          xTitle: '状态',
          yTitle: '去重计数 · 任务名称',
          formattedYField: '__formattedY',
          showDataLabels: true,
          onElementClick: datum => {
            setClickedGroup(`${String(datum.x ?? datum.name ?? '')}:${String(datum.__groupIndex ?? '')}`)
          }
        }}
      />
    </main>
  )
}

createRoot(document.getElementById('root')!).render(<InfographicRecovery />)
