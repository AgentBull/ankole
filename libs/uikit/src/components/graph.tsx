import { CanvasEvent, Graph, GraphEvent, NodeEvent, type IElementEvent } from '@antv/g6'
import {
  useCallback,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
  type MouseEvent,
  type PointerEvent,
  type ReactNode,
  type Ref
} from 'react'
import { useReducedMotion } from '../hooks/use-reduced-motion'
import { cn } from '../lib/utils'
import { useCanvasThemePalette } from './lazy-graph'
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
} from '../viz/graph-layout'

export {
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

// The spotlight outlives a pointer leave long enough to cross the gap to a neighboring node, so moving
// between nodes switches the spotlight directly instead of flashing the whole graph back to full opacity.
const HOVER_CLEAR_DELAY_MS = 180

export interface AnkoleGraphHandle {
  zoomIn: () => void
  zoomOut: () => void
  fitView: () => void
  focusNode: (nodeId: string) => void
}

export interface AnkoleGraphProps {
  nodes: readonly AnkoleGraphNode[]
  edges: readonly AnkoleGraphEdge[]
  combos?: readonly AnkoleGraphCombo[]
  layout?: AnkoleGraphLayoutMode
  ariaLabel: string
  selectedNodeId?: string | null
  highlightedNodeId?: string | null
  focusCenterNodeId?: string | null
  showEdgeLabels?: boolean
  onSelectNode?: (nodeId: string | null) => void
  onHoverNode?: (nodeId: string | null) => void
  onNavigateNode?: (node: AnkoleGraphNode, event: MouseEvent<HTMLAnchorElement>) => void
  topLeftOverlay?: ReactNode
  topRightOverlay?: ReactNode
  rightOverlay?: ReactNode
  bottomOverlay?: ReactNode
  emptyState?: ReactNode
  className?: string
  ref?: Ref<AnkoleGraphHandle>
}

export { useCanvasThemePalette }

const NO_COMBOS: readonly AnkoleGraphCombo[] = []

export function AnkoleGraph({
  nodes,
  edges,
  combos = NO_COMBOS,
  layout = 'force',
  ariaLabel,
  selectedNodeId = null,
  highlightedNodeId = null,
  focusCenterNodeId: requestedFocusCenterNodeId = null,
  showEdgeLabels = false,
  onSelectNode,
  onHoverNode,
  onNavigateNode,
  topLeftOverlay,
  topRightOverlay,
  rightOverlay,
  bottomOverlay,
  emptyState,
  className,
  ref
}: AnkoleGraphProps) {
  const palette = useCanvasThemePalette()
  const reducedMotion = useReducedMotion()
  const stageRef = useRef<HTMLDivElement | null>(null)
  const canvasHostRef = useRef<HTMLDivElement | null>(null)
  const graphRef = useRef<Graph | null>(null)
  const pointerDownRef = useRef<{ x: number; y: number } | null>(null)

  const [stageSize, setStageSize] = useState<{ width: number; height: number }>({ width: 960, height: 560 })
  const [internalHoverId, setInternalHoverId] = useState<string | null>(null)
  const [projectedAnchors, setProjectedAnchors] = useState<Map<string, ProjectedAnchor>>(() => new Map())

  const activeNodeId = highlightedNodeId ?? internalHoverId ?? selectedNodeId
  // Only the radial layout arranges itself around a focus node. Elsewhere a new focus, such as the node a click
  // selects, restyles the graph without laying it out again.
  const focusCenterNodeId = layout === 'radial' ? requestedFocusCenterNodeId : null

  // A resize keeps the drawn node positions and only resizes the canvas, so the layout reads the stage size when
  // the graph's structure changes and does not settle the force simulation again on every resize frame.
  const topology = useMemo(
    () => computeGraphTopology(nodes, edges, layout, stageSize.width, stageSize.height, focusCenterNodeId),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [nodes, edges, layout, focusCenterNodeId]
  )

  const linkableNodes = useMemo(() => nodes.filter(node => Boolean(node.href)), [nodes])

  const syncProjectedAnchors = useCallback(() => {
    const graph = graphRef.current
    if (!graph || graph.destroyed || !graph.rendered) return
    setProjectedAnchors(projectGraphAnchors(graph, linkableNodes, topology.radii))
  }, [linkableNodes, topology.radii])

  const latestSyncRef = useRef(syncProjectedAnchors)
  latestSyncRef.current = syncProjectedAnchors

  useImperativeHandle(
    ref,
    () => ({
      zoomIn() {
        const graph = graphRef.current
        if (!graph || graph.destroyed || !graph.rendered) return
        void graph.zoomBy(1.25, reducedMotion ? false : { duration: 150 }).then(
          () => latestSyncRef.current(),
          () => {}
        )
      },
      zoomOut() {
        const graph = graphRef.current
        if (!graph || graph.destroyed || !graph.rendered) return
        void graph.zoomBy(0.8, reducedMotion ? false : { duration: 150 }).then(
          () => latestSyncRef.current(),
          () => {}
        )
      },
      fitView() {
        const graph = graphRef.current
        if (!graph || graph.destroyed || !graph.rendered) return
        void graph.fitView({ when: 'always', direction: 'both' }, reducedMotion ? false : { duration: 180 }).then(
          () => latestSyncRef.current(),
          () => {}
        )
      },
      focusNode(nodeId: string) {
        const graph = graphRef.current
        if (!graph || graph.destroyed || !graph.rendered || !graph.hasNode(nodeId)) return
        void graph.focusElement(nodeId, reducedMotion ? false : { duration: 200 }).then(
          () => latestSyncRef.current(),
          () => {}
        )
      }
    }),
    [reducedMotion]
  )

  useEffect(() => {
    const stage = stageRef.current
    if (!stage || typeof ResizeObserver === 'undefined') return
    const updateSize = () => {
      const rect = stage.getBoundingClientRect()
      const width = Math.max(320, Math.round(rect.width))
      const height = Math.max(260, Math.round(rect.height))
      setStageSize(prev => (prev.width === width && prev.height === height ? prev : { width, height }))
      const graph = graphRef.current
      if (graph && !graph.destroyed && graph.rendered) {
        graph.setSize(width, height)
        latestSyncRef.current()
      }
    }
    updateSize()
    const observer = new ResizeObserver(updateSize)
    observer.observe(stage)
    return () => observer.disconnect()
  }, [])

  const graphSpec = useMemo(
    () =>
      buildG6GraphSpec({
        nodes,
        edges,
        combos,
        layout,
        width: stageSize.width,
        height: stageSize.height,
        palette,
        topology,
        selectedNodeId,
        activeNodeId,
        focusCenterNodeId,
        showEdgeLabels,
        interactive: true
      }),
    [
      activeNodeId,
      combos,
      edges,
      focusCenterNodeId,
      layout,
      nodes,
      palette,
      selectedNodeId,
      showEdgeLabels,
      stageSize.height,
      stageSize.width,
      topology
    ]
  )

  const structureKey = useMemo(() => {
    const nodeKey = nodes.map(node => `${node.id}:${node.comboId ?? ''}:${node.tier ?? ''}`).join('|')
    const edgeKey = edges.map(edge => `${edge.id}:${edge.source}->${edge.target}`).join('|')
    const comboKey = combos.map(combo => combo.id).join('|')
    return `${layout}::${focusCenterNodeId ?? ''}::${nodeKey}::${edgeKey}::${comboKey}`
  }, [combos, edges, focusCenterNodeId, layout, nodes])

  const prevStructureKeyRef = useRef<string>('')
  const latestOnSelectRef = useRef(onSelectNode)
  const latestOnHoverRef = useRef(onHoverNode)
  useEffect(() => {
    latestOnSelectRef.current = onSelectNode
    latestOnHoverRef.current = onHoverNode
  }, [onHoverNode, onSelectNode])

  const hoveredIdRef = useRef<string | null>(null)
  const hoverClearTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const cancelHoverClear = useCallback(() => {
    if (hoverClearTimerRef.current === null) return
    clearTimeout(hoverClearTimerRef.current)
    hoverClearTimerRef.current = null
  }, [])
  const enterNodeHover = useCallback(
    (nodeId: string) => {
      cancelHoverClear()
      if (hoveredIdRef.current === nodeId) return
      hoveredIdRef.current = nodeId
      setInternalHoverId(nodeId)
      latestOnHoverRef.current?.(nodeId)
    },
    [cancelHoverClear]
  )
  const leaveNodeHover = useCallback(
    (nodeId: string) => {
      // The canvas and the link layer report enter and leave independently, so a late leave from the
      // previous node must not touch the spotlight that a newer enter already moved.
      if (hoveredIdRef.current !== nodeId) return
      cancelHoverClear()
      hoverClearTimerRef.current = setTimeout(() => {
        hoverClearTimerRef.current = null
        if (hoveredIdRef.current !== nodeId) return
        hoveredIdRef.current = null
        setInternalHoverId(null)
        latestOnHoverRef.current?.(null)
      }, HOVER_CLEAR_DELAY_MS)
    },
    [cancelHoverClear]
  )

  useEffect(() => {
    const host = canvasHostRef.current
    if (!host) return

    const graph = new Graph({
      container: host,
      width: stageSize.width,
      height: stageSize.height,
      autoResize: false,
      animation: !reducedMotion,
      zoomRange: [0.22, 3.5],
      autoFit: { type: 'view', options: { when: 'overflow', direction: 'both' } },
      padding: [36, 36, 36, 36]
    })

    const handleSync = () => latestSyncRef.current()
    const handleNodeClick = (event: IElementEvent) => {
      const id = event.target.id
      if (id) latestOnSelectRef.current?.(String(id))
    }
    const handleNodeEnter = (event: IElementEvent) => {
      const id = event.target.id
      if (id) enterNodeHover(String(id))
    }
    const handleNodeLeave = (event: IElementEvent) => {
      const id = event.target.id
      if (id) leaveNodeHover(String(id))
    }
    const handleCanvasClick = () => {
      latestOnSelectRef.current?.(null)
    }

    // G6 gives every canvas layer `tabindex="1"`. The canvas host is hidden from assistive technology
    // and the node links carry keyboard access, so the canvases leave the tab order.
    graph.on(GraphEvent.AFTER_CANVAS_INIT, () => {
      for (const canvas of host.querySelectorAll('canvas')) canvas.tabIndex = -1
    })
    graph.on(GraphEvent.AFTER_RENDER, handleSync)
    graph.on(GraphEvent.AFTER_LAYOUT, handleSync)
    graph.on(GraphEvent.AFTER_TRANSFORM, handleSync)
    graph.on(GraphEvent.AFTER_ELEMENT_TRANSLATE, handleSync)
    graph.on(GraphEvent.AFTER_SIZE_CHANGE, handleSync)
    graph.on<IElementEvent>(NodeEvent.CLICK, handleNodeClick)
    graph.on<IElementEvent>(NodeEvent.POINTER_ENTER, handleNodeEnter)
    graph.on<IElementEvent>(NodeEvent.POINTER_LEAVE, handleNodeLeave)
    graph.on(CanvasEvent.CLICK, handleCanvasClick)

    graphRef.current = graph

    return () => {
      cancelHoverClear()
      prevStructureKeyRef.current = ''
      graphRef.current = null
      graph.destroy()
    }
    // Graph lifecycle binds once to the DOM container; size, theme, layout, and data update reactively below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    const graph = graphRef.current
    if (!graph || graph.destroyed) return

    if (nodes.length === 0) {
      prevStructureKeyRef.current = structureKey
      void graph.clear().catch(() => {})
      setProjectedAnchors(new Map())
      return
    }

    const structureChanged = prevStructureKeyRef.current !== structureKey
    prevStructureKeyRef.current = structureKey

    if (structureChanged) {
      graph.setOptions({
        animation: !reducedMotion,
        data: graphSpec.data,
        layout: graphSpec.layoutOptions,
        transforms: graphSpec.transforms,
        behaviors: graphSpec.behaviors
      })
      void graph.render().then(
        () => latestSyncRef.current(),
        () => {}
      )
    } else {
      // Style-only change (hover spotlight, selection, edge-label toggle, or theme switch): preserve settled
      // layout coordinates and redraw elements in place without re-running the layout. The spotlight restyles
      // nearly every element, and the motion it would get is a stroke-color fade on the focused node, so the
      // redraw skips animation instead of building a few hundred animations on every pointer move.
      const preservedNodes = graphSpec.data.nodes.map(node => {
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
      graph.setData({
        nodes: preservedNodes,
        edges: graphSpec.data.edges,
        combos: graphSpec.data.combos
      })
      graph.setOptions({ animation: false })
      void graph
        .draw()
        .then(
          () => latestSyncRef.current(),
          () => {}
        )
        .finally(() => {
          if (!graph.destroyed) graph.setOptions({ animation: !reducedMotion })
        })
    }
  }, [graphSpec, nodes.length, reducedMotion, structureKey, syncProjectedAnchors])

  const forwardWheelToCanvas = useCallback((event: React.WheelEvent<HTMLAnchorElement>) => {
    const host = canvasHostRef.current
    if (!host) return
    const canvas =
      Array.from(host.querySelectorAll('canvas')).find(element => element.style.pointerEvents !== 'none') ??
      host.querySelector('canvas')
    if (!canvas) return
    canvas.dispatchEvent(
      new WheelEvent('wheel', {
        deltaX: event.deltaX,
        deltaY: event.deltaY,
        deltaZ: event.deltaZ,
        deltaMode: event.deltaMode,
        clientX: event.clientX,
        clientY: event.clientY,
        ctrlKey: event.ctrlKey,
        metaKey: event.metaKey,
        shiftKey: event.shiftKey,
        bubbles: true,
        cancelable: true
      })
    )
  }, [])

  return (
    <div
      ref={stageRef}
      className={cn(
        'relative isolate min-h-[520px] w-full overflow-hidden rounded-control border border-border bg-background select-none overscroll-contain',
        className
      )}>
      <div role="group" aria-label={ariaLabel} className="absolute inset-0">
        <div ref={canvasHostRef} className="absolute inset-0 touch-none" aria-hidden="true" />

        {/* Synchronized semantic link layer: gives keyboard users, screen readers, and native
            browser Cmd/Ctrl+Click actions exact accessible anchors over every navigable graph node. */}
        <div className="pointer-events-none absolute inset-0 z-10 overflow-hidden">
          {linkableNodes.map(node => {
            const projected = projectedAnchors.get(node.id)
            const fallback = topology.initialPositions.get(node.id) ?? {
              x: stageSize.width / 2,
              y: stageSize.height / 2
            }
            const x = projected ? projected.x : fallback.x
            const y = projected ? projected.y : fallback.y
            const size = projected ? projected.size : Math.max(24, (topology.radii.get(node.id) ?? 10) * 2 + 8)
            const visible = projected ? projected.visible : true

            return (
              <a
                key={node.id}
                href={node.href}
                aria-label={node.label}
                title={node.subtitle ? `${node.label} · ${node.subtitle}` : node.label}
                style={{
                  left: `${Math.round(x - size / 2)}px`,
                  top: `${Math.round(y - size / 2)}px`,
                  width: `${size}px`,
                  height: `${size}px`,
                  visibility: visible ? 'visible' : 'hidden'
                }}
                onPointerDown={(event: PointerEvent<HTMLAnchorElement>) => {
                  pointerDownRef.current = { x: event.clientX, y: event.clientY }
                }}
                onPointerEnter={() => enterNodeHover(node.id)}
                onPointerLeave={() => leaveNodeHover(node.id)}
                onFocus={() => {
                  enterNodeHover(node.id)
                  onSelectNode?.(node.id)
                }}
                onBlur={() => leaveNodeHover(node.id)}
                onWheel={forwardWheelToCanvas}
                onClick={event => {
                  const start = pointerDownRef.current
                  pointerDownRef.current = null
                  if (start && Math.hypot(event.clientX - start.x, event.clientY - start.y) > 5) {
                    event.preventDefault()
                    return
                  }
                  onSelectNode?.(node.id)
                  if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
                    return
                  }
                  if (onNavigateNode) {
                    event.preventDefault()
                    onNavigateNode(node, event)
                  }
                }}
                className="pointer-events-auto absolute rounded-full outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background"
              />
            )
          })}
        </div>
      </div>

      {nodes.length === 0 && emptyState && (
        <div className="pointer-events-none absolute inset-0 z-20 flex items-center justify-center p-6">
          <div className="pointer-events-auto">{emptyState}</div>
        </div>
      )}

      {topLeftOverlay && (
        <div className="pointer-events-none absolute top-3 left-3 z-20 max-h-[calc(100%-24px)] max-w-[min(280px,calc(100%-24px))] overflow-y-auto">
          <div className="pointer-events-auto">{topLeftOverlay}</div>
        </div>
      )}

      {topRightOverlay && (
        <div className="pointer-events-none absolute top-3 right-3 z-20 flex items-center gap-2">
          <div className="pointer-events-auto">{topRightOverlay}</div>
        </div>
      )}

      {rightOverlay && (
        <div className="pointer-events-none absolute top-14 right-3 bottom-3 z-20 flex max-w-[min(320px,calc(100%-24px))] flex-col justify-start overflow-hidden">
          <div className="pointer-events-auto max-h-full overflow-y-auto">{rightOverlay}</div>
        </div>
      )}

      {bottomOverlay && (
        <div className="pointer-events-none absolute bottom-3 left-3 z-20 max-w-[calc(100%-24px)]">
          <div className="pointer-events-auto">{bottomOverlay}</div>
        </div>
      )}
    </div>
  )
}
