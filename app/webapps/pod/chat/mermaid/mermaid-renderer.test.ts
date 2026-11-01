import { describe, expect, test } from 'bun:test'
import { computePinchTransform, orderBufferedSlots, scheduleAnimationFrames } from '../zoomable-image'
import { buildMermaidSrcDoc, MERMAID_FRAME_CSP } from './mermaid-frame'
import { svgToPngBlob } from './mermaid-download'
import {
  formatMermaidRenderError,
  getCachedMermaidDiagram,
  injectStandaloneSvgTheme,
  renderMermaidDiagram
} from './mermaid-renderer'

describe('renderMermaidDiagram (pele)', () => {
  test('rejects PNG exports beyond the canvas budget before decoding or allocating', async () => {
    await expect(svgToPngBlob('<svg />', 10_000, 10_000, 'light')).rejects.toThrow('too large')
  })

  test('renders valid flowchart SVG without external script or link execution and caches by theme + code', async () => {
    const source = 'flowchart LR\n  A["User Request"] --> B["Control Plane"]\n  B --> C["Worker"]'
    const light = await renderMermaidDiagram(source, 'light')
    expect(light.svg).toContain('<svg')
    expect(light.svg).toContain('User Request')
    expect(light.width).toBeGreaterThan(20)
    expect(light.height).toBeGreaterThan(20)
    expect(getCachedMermaidDiagram(source, 'light')).toBe(light)
    expect(getCachedMermaidDiagram(source, 'dark')).toBeUndefined()

    const dark = await renderMermaidDiagram(source, 'dark')
    expect(dark.svg).toContain('<svg')
    expect(getCachedMermaidDiagram(source, 'dark')).toBe(dark)
  })

  test('evicts oldest entry once 48-entry LRU cache fills', async () => {
    for (let i = 0; i < 49; i += 1) {
      await renderMermaidDiagram(`flowchart LR\n  LRU_N${i} --> LRU_M${i}`, 'light')
    }
    expect(getCachedMermaidDiagram('flowchart LR\n  LRU_N0 --> LRU_M0', 'light')).toBeUndefined()
    expect(getCachedMermaidDiagram('flowchart LR\n  LRU_N48 --> LRU_M48', 'light')).toBeDefined()
  })

  test('rejects incomplete streaming or invalid Mermaid syntax cleanly with single-line error reason', async () => {
    let caught: unknown = null
    try {
      await renderMermaidDiagram('not_a_mermaid_diagram $$$ @@@', 'light')
    } catch (err) {
      caught = err
    }
    expect(caught).not.toBeNull()
    const reason = formatMermaidRenderError(caught)
    expect(reason.length).toBeGreaterThan(0)
    expect(reason).not.toContain('\n')
  })

  test('builds isolated srcDoc with strict CSP and standalone SVG theme variables', async () => {
    const diagram = await renderMermaidDiagram('sequenceDiagram\n  Alice->>Bob: Hello', 'dark')
    const doc = buildMermaidSrcDoc({
      svg: diagram.svg,
      theme: 'dark',
      width: diagram.width,
      height: diagram.height,
      scale: 2,
      fitContainer: false
    })
    expect(doc).toContain(MERMAID_FRAME_CSP)
    expect(doc).toContain("default-src 'none'")
    expect(doc).toContain(`width:${Math.round(diagram.width * 2)}px`)
    expect(doc).toContain('translate="no"')

    const standalone = injectStandaloneSvgTheme(diagram.svg, 'light')
    expect(standalone).toContain('xmlns="http://www.w3.org/2000/svg"')
    expect(standalone).toContain('--pele-bg:#fffefd')
  })

  test('double-buffered zoom slots keep ascending React keys across prepared -> committed -> retiring and support 2-finger pinch', async () => {
    const beforePromote = orderBufferedSlots({ key: 1, scale: 1 }, { key: 2, scale: 2 }, null)
    expect(beforePromote.map(s => ({ key: s.key, role: s.role, zIndex: s.zIndex }))).toEqual([
      { key: 1, role: 'committed', zIndex: 1 },
      { key: 2, role: 'prepared', zIndex: 0 }
    ])

    const afterPromote = orderBufferedSlots({ key: 2, scale: 2 }, null, { key: 1, scale: 1 })
    expect(afterPromote.map(s => ({ key: s.key, role: s.role, zIndex: s.zIndex }))).toEqual([
      { key: 1, role: 'retiring', zIndex: 2 },
      { key: 2, role: 'committed', zIndex: 1 }
    ])

    const pinch = computePinchTransform(
      { startDist: 100, startZoom: 1, startMidX: 200, startMidY: 200, panX: 10, panY: -5 },
      { x: 110, y: 220 },
      { x: 310, y: 220 }
    )
    expect(pinch.zoom).toBe(2)
    expect(pinch.pan).toEqual({ x: 20, y: 15 })

    let fired = false
    const cancel = scheduleAnimationFrames(2, () => {
      fired = true
    })
    cancel()
    await new Promise(resolve => setTimeout(resolve, 60))
    expect(fired).toBe(false)
  })
})
