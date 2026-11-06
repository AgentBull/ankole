import { Renderer as SVGRenderer } from '@antv/g-svg'
import { CanvasEvent, Graph, NodeEvent, type IElementEvent } from '@antv/g6'
import {
  buildG6GraphSpec,
  computeGraphTopology,
  projectGraphAnchors,
  resolveCanvasThemePalette,
  type AnkoleCanvasThemePalette,
  type AnkoleGraphColorRamp,
  type AnkoleGraphCombo,
  type AnkoleGraphEdge,
  type AnkoleGraphLayoutMode,
  type AnkoleGraphNode,
  type AnkoleGraphNodeShape,
  type AnkoleGraphRampColors,
  type AnkoleGraphTopology,
  type GraphViewportReader,
  type ProjectedAnchor
} from './graph-layout'
import { resolveVizTheme, sanitizeExportedSvg, type VizThemeMode } from './theme'

export {
  buildG6GraphSpec,
  computeGraphTopology,
  projectGraphAnchors,
  resolveCanvasThemePalette,
  type AnkoleCanvasThemePalette,
  type AnkoleGraphColorRamp,
  type AnkoleGraphCombo,
  type AnkoleGraphEdge,
  type AnkoleGraphLayoutMode,
  type AnkoleGraphNode,
  type AnkoleGraphNodeShape,
  type AnkoleGraphRampColors,
  type AnkoleGraphTopology,
  type GraphViewportReader,
  type ProjectedAnchor
}

export interface GraphVizSpec {
  nodes: readonly AnkoleGraphNode[]
  edges: readonly AnkoleGraphEdge[]
  combos?: readonly AnkoleGraphCombo[]
  layout?: AnkoleGraphLayoutMode
  renderer?: 'canvas' | 'svg'
  theme?: VizThemeMode
  width?: number
  height?: number
  selectedNodeId?: string | null
  highlightedNodeId?: string | null
  focusCenterNodeId?: string | null
  showEdgeLabels?: boolean
  animate?: boolean
  interactive?: boolean
  onSelectNode?: (nodeId: string | null) => void
  onHoverNode?: (nodeId: string | null) => void
}

export interface MountedGraphViz {
  update: (nextSpec: GraphVizSpec) => Promise<void>
  resize: (width: number, height: number) => void
  fitView: () => Promise<void>
  focusNode: (nodeId: string) => Promise<void>
  exportSVG: () => Promise<string>
  exportPNG: (options?: { dpr?: number }) => Promise<string>
  destroy: () => void
}

async function rasterizeSvgToPng(svgMarkup: string, width: number, height: number, dpr: number): Promise<string> {
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round(width * dpr))
  canvas.height = Math.max(1, Math.round(height * dpr))
  const ctx = canvas.getContext('2d')
  if (!ctx) throw new Error('Failed to acquire 2D canvas context.')
  ctx.scale(dpr, dpr)
  const url = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svgMarkup)}`
  await new Promise<void>((resolve, reject) => {
    const img = new Image()
    img.onload = () => {
      ctx.drawImage(img, 0, 0, width, height)
      resolve()
    }
    img.onerror = () => reject(new Error('Failed to rasterize SVG graph to PNG.'))
    img.src = url
  })
  return canvas.toDataURL('image/png')
}

/**
 * Mounts a framework-agnostic `@antv/g6` v5 topology graph inside `host`, supporting both
 * interactive multi-layer Canvas rendering and unified single-layer `@antv/g-svg` vector
 * rendering for Print-Safe SVG export.
 */
export async function mountGraphViz(host: HTMLElement, initialSpec: GraphVizSpec): Promise<MountedGraphViz> {
  let currentSpec = initialSpec
  const rect = host.getBoundingClientRect()
  let currentWidth = initialSpec.width ?? Math.max(320, Math.round(rect.width) || 800)
  let currentHeight = initialSpec.height ?? Math.max(260, Math.round(rect.height) || 520)

  const useSvgRenderer = initialSpec.renderer === 'svg'
  const animate = useSvgRenderer ? false : (initialSpec.animate ?? true)

  let canvasPalette = resolveCanvasThemePalette(host, currentSpec.theme)
  let vizPalette = resolveVizTheme(host, { theme: currentSpec.theme })

  const createBuiltSpec = (spec: GraphVizSpec, palette: AnkoleCanvasThemePalette, interactiveOverride?: boolean) => {
    const layout = spec.layout ?? 'force'
    const topology = computeGraphTopology(
      spec.nodes,
      spec.edges,
      layout,
      currentWidth,
      currentHeight,
      spec.focusCenterNodeId
    )
    return buildG6GraphSpec({
      nodes: spec.nodes,
      edges: spec.edges,
      combos: spec.combos,
      layout,
      width: currentWidth,
      height: currentHeight,
      palette,
      topology,
      selectedNodeId: spec.selectedNodeId,
      activeNodeId: spec.highlightedNodeId ?? spec.selectedNodeId,
      focusCenterNodeId: spec.focusCenterNodeId,
      showEdgeLabels: spec.showEdgeLabels,
      reducedMotion: !animate,
      interactive: interactiveOverride ?? spec.interactive ?? !useSvgRenderer
    })
  }

  const initialBuilt = createBuiltSpec(currentSpec, canvasPalette)

  const graph = new Graph({
    container: host,
    width: currentWidth,
    height: currentHeight,
    autoResize: false,
    animation: animate,
    background: canvasPalette.background,
    zoomRange: [0.22, 3.5],
    autoFit: { type: 'view', options: { when: 'overflow', direction: 'both' } },
    padding: [36, 36, 36, 36],
    transforms: [{ type: 'process-parallel-edges', key: 'parallel-edges', distance: 24 }],
    data: initialBuilt.data,
    layout: initialBuilt.layoutOptions,
    behaviors: initialBuilt.behaviors,
    ...(useSvgRenderer
      ? {
          canvas: { enableMultiLayer: false },
          renderer: () => new SVGRenderer() as never
        }
      : {})
  })

  const handleNodeClick = (event: IElementEvent) => {
    const id = event.target.id
    if (id) currentSpec.onSelectNode?.(String(id))
  }
  const handleNodeEnter = (event: IElementEvent) => {
    const id = event.target.id
    if (id) currentSpec.onHoverNode?.(String(id))
  }
  const handleNodeLeave = () => {
    currentSpec.onHoverNode?.(null)
  }
  const handleCanvasClick = () => {
    currentSpec.onSelectNode?.(null)
  }

  graph.on<IElementEvent>(NodeEvent.CLICK, handleNodeClick)
  graph.on<IElementEvent>(NodeEvent.POINTER_ENTER, handleNodeEnter)
  graph.on(NodeEvent.POINTER_LEAVE, handleNodeLeave)
  graph.on(CanvasEvent.CLICK, handleCanvasClick)

  if (currentSpec.nodes.length > 0) {
    await graph.render()
  }

  let destroyed = false

  const exportSVG = async (): Promise<string> => {
    if (destroyed || graph.destroyed) {
      throw new Error('Graph visualization instance has been destroyed.')
    }

    if (useSvgRenderer) {
      const svgEl = host.querySelector('svg')
      if (svgEl) {
        const raw = new XMLSerializer().serializeToString(svgEl)
        return sanitizeExportedSvg(raw, vizPalette, { safetyPaddingPx: 12 })
      }
    }

    const tempHost = document.createElement('div')
    tempHost.style.cssText = `position:fixed;left:-99999px;top:-99999px;width:${currentWidth}px;height:${currentHeight}px;pointer-events:none;`
    document.body.appendChild(tempHost)

    const exportBuilt = createBuiltSpec(currentSpec, canvasPalette, false)
    const positionedNodes = exportBuilt.data.nodes.map(node => {
      if (graph.rendered && graph.hasNode(node.id)) {
        try {
          const pos = graph.getElementPosition(node.id)
          return {
            ...node,
            style: {
              ...node.style,
              x: pos[0],
              y: pos[1]
            }
          }
        } catch {
          return node
        }
      }
      return node
    })

    const tempGraph = new Graph({
      container: tempHost,
      width: currentWidth,
      height: currentHeight,
      autoResize: false,
      animation: false,
      background: canvasPalette.background,
      autoFit: { type: 'view', options: { when: 'overflow', direction: 'both' } },
      padding: [36, 36, 36, 36],
      transforms: [{ type: 'process-parallel-edges', key: 'parallel-edges', distance: 24 }],
      canvas: { enableMultiLayer: false },
      renderer: () => new SVGRenderer() as never,
      data: {
        nodes: positionedNodes,
        edges: exportBuilt.data.edges,
        combos: exportBuilt.data.combos
      },
      ...(graph.rendered ? {} : { layout: exportBuilt.layoutOptions }),
      behaviors: []
    })

    try {
      if (positionedNodes.length > 0) {
        await tempGraph.render()
      }
      const svgEl = tempHost.querySelector('svg')
      if (!svgEl) {
        throw new Error('Failed to extract SVG markup from G6 SVG renderer.')
      }
      const raw = new XMLSerializer().serializeToString(svgEl)
      return sanitizeExportedSvg(raw, vizPalette, { safetyPaddingPx: 12 })
    } finally {
      tempGraph.destroy()
      tempHost.remove()
    }
  }

  return {
    async update(nextSpec: GraphVizSpec) {
      if (destroyed || graph.destroyed) return
      currentSpec = nextSpec
      if (nextSpec.width) currentWidth = nextSpec.width
      if (nextSpec.height) currentHeight = nextSpec.height
      canvasPalette = resolveCanvasThemePalette(host, currentSpec.theme)
      vizPalette = resolveVizTheme(host, { theme: currentSpec.theme })

      if (currentSpec.nodes.length === 0) {
        await graph.clear()
        return
      }

      const nextBuilt = createBuiltSpec(currentSpec, canvasPalette)
      graph.setOptions({
        animation: useSvgRenderer ? false : (currentSpec.animate ?? true),
        background: canvasPalette.background,
        data: nextBuilt.data,
        layout: nextBuilt.layoutOptions,
        behaviors: nextBuilt.behaviors
      })
      await graph.render()
    },
    resize(width: number, height: number) {
      if (destroyed || graph.destroyed) return
      currentWidth = Math.max(240, Math.round(width))
      currentHeight = Math.max(200, Math.round(height))
      if (graph.rendered) {
        graph.setSize(currentWidth, currentHeight)
      }
    },
    async fitView() {
      if (destroyed || graph.destroyed || !graph.rendered) return
      await graph.fitView({ when: 'always', direction: 'both' }, animate ? { duration: 180 } : false)
    },
    async focusNode(nodeId: string) {
      if (destroyed || graph.destroyed || !graph.rendered || !graph.hasNode(nodeId)) return
      await graph.focusElement(nodeId, animate ? { duration: 200 } : false)
    },
    exportSVG,
    async exportPNG(options) {
      if (destroyed || graph.destroyed) {
        throw new Error('Graph visualization instance has been destroyed.')
      }
      if (!useSvgRenderer && graph.rendered) {
        return graph.toDataURL({ mode: 'viewport', type: 'image/png' })
      }
      const svg = await exportSVG()
      return rasterizeSvgToPng(svg, currentWidth, currentHeight, options?.dpr ?? 2)
    },
    destroy() {
      if (destroyed) return
      destroyed = true
      graph.destroy()
    }
  }
}
