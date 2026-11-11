import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import {
  AnkoleGraph,
  computeGraphTopology,
  projectGraphAnchors,
  resolveCanvasThemePalette,
  type AnkoleGraphEdge,
  type AnkoleGraphNode
} from '../src/components/graph'

const SAMPLE_NODES: AnkoleGraphNode[] = [
  { id: 'cat:companies', label: 'companies', tier: 'hub', ramp: 'blue' },
  { id: 'obj:acme', label: 'Acme Corp', parentId: 'cat:companies', ramp: 'blue', href: '/meta/brain/obj:acme' },
  { id: 'obj:cloud', label: 'Acme Cloud', parentId: 'obj:acme', ramp: 'blue', href: '/meta/brain/obj:cloud' },
  { id: 'obj:report', label: 'Q3 Analysis', ramp: 'purple', href: '/meta/brain/obj:report' }
]

const SAMPLE_EDGES: AnkoleGraphEdge[] = [
  { id: 'e1', source: 'cat:companies', target: 'obj:acme', kind: 'hierarchy' },
  { id: 'e2', source: 'obj:acme', target: 'obj:cloud', kind: 'hierarchy', label: 'contains' },
  { id: 'e3', source: 'obj:report', target: 'obj:acme', kind: 'relation', label: 'references' },
  { id: 'e4', source: 'obj:report', target: 'obj:cloud', kind: 'relation', label: 'evidences' }
]

describe('AnkoleGraph', () => {
  test('computes degree centrality, hub prominence, and distinct coordinates across all four standard layouts', () => {
    for (const mode of ['force', 'hierarchy', 'combo', 'radial'] as const) {
      const topology = computeGraphTopology(SAMPLE_NODES, SAMPLE_EDGES, mode, 960, 560)
      expect(topology.degrees.get('obj:acme')).toBe(3)
      expect(topology.degrees.get('obj:cloud')).toBe(2)
      expect(topology.neighbors.get('obj:acme')).toEqual(new Set(['cat:companies', 'obj:cloud', 'obj:report']))
      expect((topology.radii.get('cat:companies') ?? 0) > (topology.radii.get('obj:cloud') ?? 0)).toBe(true)
      expect(topology.initialPositions.size).toBe(SAMPLE_NODES.length)

      if (mode === 'hierarchy') {
        const hubY = topology.initialPositions.get('cat:companies')!.y
        const parentY = topology.initialPositions.get('obj:acme')!.y
        const childY = topology.initialPositions.get('obj:cloud')!.y
        expect(hubY).toBeLessThan(parentY)
        expect(parentY).toBeLessThan(childY)
      }
    }
  })

  test('resolves light and dark fallback palettes and renders accessible object links without turning hubs into links', () => {
    const palette = resolveCanvasThemePalette(null)
    expect(palette.isDark).toBe(false)
    expect(palette.ramps.blue.fill).toBe('#2e6eeb')

    const html = renderToStaticMarkup(
      <AnkoleGraph
        ariaLabel="知识图谱"
        nodes={SAMPLE_NODES}
        edges={SAMPLE_EDGES}
        layout="force"
        rightOverlay={<a href="/meta/brain/obj:acme">打开知识条目</a>}
      />
    )

    expect(html).toContain('role="group"')
    expect(html).toContain('aria-label="知识图谱"')
    expect(html).toContain('href="/meta/brain/obj:acme"')
    expect(html).toContain('aria-label="Acme Corp"')
    expect(html).not.toContain('aria-label="companies"')
    expect(html).toContain('打开知识条目')
  })

  test('projects linkable nodes across pan, zoom, and filter updates while culling off-viewport anchors', () => {
    const linkable = SAMPLE_NODES.filter(node => Boolean(node.href))
    const radii = new Map<string, number>([
      ['obj:acme', 14],
      ['obj:cloud', 11],
      ['obj:report', 10]
    ])
    let panX = 0
    let panY = 0
    let zoom = 1
    const activeNodeIds = new Set(['obj:acme', 'obj:cloud', 'obj:report'])
    const positions: Record<string, [number, number]> = {
      'obj:acme': [220, 180],
      'obj:cloud': [400, 260],
      'obj:report': [780, 500]
    }
    const fakeViewport = {
      getZoom: () => zoom,
      getSize: (): [number, number] => [800, 520],
      hasNode: (id: string) => activeNodeIds.has(id),
      getElementPosition: (id: string): [number, number] => positions[id]!,
      getViewportByCanvas: ([x, y]: [number, number, ...number[]]): [number, number] => [
        x * zoom + panX,
        y * zoom + panY
      ]
    }

    const initial = projectGraphAnchors(fakeViewport, linkable, radii)
    expect(initial.get('obj:acme')).toEqual({ x: 220, y: 180, size: 38, visible: true })

    panX = 120
    panY = -45
    zoom = 1.5
    const transformed = projectGraphAnchors(fakeViewport, linkable, radii)
    expect(transformed.get('obj:acme')).toEqual({ x: 450, y: 225, size: 52, visible: true })
    // `780 * 1.5 + 120 = 1290` exceeds viewport width + margin, so off-screen anchors hide cleanly.
    expect(transformed.get('obj:report')?.visible).toBe(false)

    activeNodeIds.delete('obj:cloud')
    const filtered = projectGraphAnchors(
      fakeViewport,
      linkable.filter(node => node.id !== 'obj:cloud'),
      radii
    )
    expect(filtered.has('obj:cloud')).toBe(false)
    expect(filtered.get('obj:acme')?.x).toBe(450)
  })
})
