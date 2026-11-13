import type { ComboData, EdgeData, GraphOptions, NodeData, Point } from '@antv/g6'
import {
  forceCenter,
  forceCollide,
  forceLink,
  forceManyBody,
  forceSimulation,
  forceX,
  forceY,
  type SimulationLinkDatum,
  type SimulationNodeDatum
} from 'd3-force'

export type AnkoleGraphColorRamp =
  | 'blue'
  | 'teal'
  | 'purple'
  | 'brand'
  | 'green'
  | 'orange'
  | 'cyan'
  | 'magenta'
  | 'yellow'
  | 'gray'

export type AnkoleGraphNodeShape = 'circle' | 'diamond' | 'hexagon' | 'rect'

export type AnkoleGraphLayoutMode = 'force' | 'hierarchy' | 'combo' | 'radial'

export interface AnkoleGraphNode {
  id: string
  label: string
  subtitle?: string
  ramp?: AnkoleGraphColorRamp
  shape?: AnkoleGraphNodeShape
  comboId?: string
  parentId?: string | null
  tier?: 'hub' | 'object'
  href?: string
  weight?: number
}

export interface AnkoleGraphEdge {
  id: string
  source: string
  target: string
  label?: string
  ramp?: AnkoleGraphColorRamp
  dashed?: boolean
  kind?: 'hierarchy' | 'relation'
}

export interface AnkoleGraphCombo {
  id: string
  label: string
  ramp?: AnkoleGraphColorRamp
  parentId?: string
}

export interface AnkoleGraphRampColors {
  fill: string
  stroke: string
  subtle: string
  text: string
}

export interface AnkoleCanvasThemePalette {
  isDark: boolean
  background: string
  layer01: string
  layer02: string
  foreground: string
  fgSecondary: string
  fgTertiary: string
  border: string
  borderStrong: string
  ring: string
  selection: string
  fontSans: string
  fontMono: string
  ramps: Record<AnkoleGraphColorRamp, AnkoleGraphRampColors>
}

const ALL_RAMPS: readonly AnkoleGraphColorRamp[] = [
  'blue',
  'teal',
  'purple',
  'brand',
  'green',
  'orange',
  'cyan',
  'magenta',
  'yellow',
  'gray'
]

type RampStep = 10 | 30 | 50 | 60 | 70 | 80 | 90

const FALLBACK_RAMP_STEPS: Record<AnkoleGraphColorRamp, Record<RampStep, string>> = {
  blue: { 10: '#eaeff8', 30: '#9fc2ff', 50: '#0f87ff', 60: '#2e6eeb', 70: '#0d54da', 80: '#1f44ae', 90: '#1e3d8a' },
  teal: { 10: '#d0faf1', 30: '#8eedd9', 50: '#20d6be', 60: '#19bfa1', 70: '#15ad95', 80: '#117465', 90: '#135c53' },
  purple: { 10: '#eae8f6', 30: '#bdafff', 50: '#8c62f9', 60: '#753de4', 70: '#6a30d1', 80: '#5828af', 90: '#49238f' },
  brand: { 10: '#ffeaed', 30: '#ff9aa5', 50: '#ff5468', 60: '#ff4669', 70: '#e72b41', 80: '#a0141c', 90: '#a6183a' },
  green: { 10: '#d7fce6', 30: '#6ae8ab', 50: '#3abe84', 60: '#2cc469', 70: '#058b5b', 80: '#067651', 90: '#075e41' },
  orange: { 10: '#fef3e6', 30: '#ffbea3', 50: '#ff814a', 60: '#f7630c', 70: '#cc4f00', 80: '#933600', 90: '#7b2913' },
  cyan: { 10: '#eaf8ff', 30: '#ace4ff', 50: '#60ceff', 60: '#25c3fd', 70: '#009ed0', 80: '#006f93', 90: '#045f88' },
  magenta: { 10: '#fbecf5', 30: '#ffcae4', 50: '#ff63a7', 60: '#ff4890', 70: '#f0125f', 80: '#d10545', 90: '#ad0739' },
  yellow: { 10: '#fffeca', 30: '#fffa7d', 50: '#fff200', 60: '#ffe500', 70: '#d1aa00', 80: '#a67a02', 90: '#895f0a' },
  gray: { 10: '#fbfbfb', 30: '#f4f4f4', 50: '#d3d3d3', 60: '#b6b6b6', 70: '#929292', 80: '#5e5e5e', 90: '#424242' }
}

/**
 * The step a ramp's marks take on a light surface. The hues do not share one lightness ladder, so each ramp
 * names the lightest of its steps 60–80 that keeps 3:1 on white; the neutral ramp stays at 60 because gray
 * marks recede on purpose. The stroke is one step darker than the fill.
 */
const LIGHT_MARK_STEP: Record<AnkoleGraphColorRamp, 60 | 70 | 80> = {
  blue: 60,
  teal: 80,
  purple: 60,
  brand: 60,
  green: 70,
  orange: 60,
  cyan: 70,
  magenta: 60,
  yellow: 80,
  gray: 60
}

function readToken(styles: CSSStyleDeclaration | null, name: string, fallback: string): string {
  const value = styles?.getPropertyValue(name).trim()
  return value ? value : fallback
}

/**
 * Resolves Ankole's CSS custom properties into concrete canvas colors shared by
 * `@antv/g6` and canvas chart surfaces.
 */
export function resolveCanvasThemePalette(
  root?: Element | null,
  themeOverride?: 'auto' | 'light' | 'dark'
): AnkoleCanvasThemePalette {
  const target = root === undefined ? (typeof document !== 'undefined' ? document.documentElement : null) : root
  const domIsDark = target?.getAttribute('data-theme') === 'dark'
  const isDark = themeOverride === 'dark' ? true : themeOverride === 'light' ? false : Boolean(domIsDark)
  const styles =
    target && typeof window !== 'undefined' && (!themeOverride || themeOverride === 'auto' || domIsDark === isDark)
      ? window.getComputedStyle(target)
      : null

  const ramps = {} as Record<AnkoleGraphColorRamp, AnkoleGraphRampColors>
  for (const ramp of ALL_RAMPS) {
    const fallback = FALLBACK_RAMP_STEPS[ramp]
    const step = (value: RampStep) => readToken(styles, `--color-${ramp}-${value}`, fallback[value])
    const mark = LIGHT_MARK_STEP[ramp]
    ramps[ramp] = isDark
      ? { fill: step(50), stroke: step(30), subtle: step(90), text: step(30) }
      : { fill: step(mark), stroke: step((mark + 10) as RampStep), subtle: step(10), text: step(90) }
  }

  return {
    isDark,
    background: readToken(styles, '--background', isDark ? '#0b0b0b' : '#ffffff'),
    layer01: readToken(styles, '--layer-01', isDark ? '#000000' : '#f8f8f8'),
    layer02: readToken(styles, '--layer-02', isDark ? '#0b0b0b' : '#ffffff'),
    foreground: readToken(styles, '--foreground', isDark ? '#ffffff' : '#424242'),
    fgSecondary: readToken(styles, '--fg-secondary', isDark ? '#f8f8f8' : '#5e5e5e'),
    fgTertiary: readToken(styles, '--fg-tertiary', isDark ? '#d3d3d3' : '#929292'),
    border: readToken(styles, '--border', isDark ? '#1c1c1e' : '#d3d3d3'),
    borderStrong: readToken(styles, '--border-strong', '#929292'),
    ring: readToken(styles, '--ring', isDark ? '#e72b41' : '#ff4669'),
    selection: readToken(styles, '--selection', isDark ? 'rgb(160 20 28 / 0.26)' : 'rgb(255 154 165 / 0.3)'),
    fontSans: readToken(styles, '--font-family-sans', "'AgentBullSansGB', 'Helvetica Neue', Arial, sans-serif"),
    fontMono: readToken(styles, '--font-family-mono', "'AgentBullMono', monospace"),
    ramps
  }
}

export interface AnkoleGraphTopology {
  degrees: Map<string, number>
  neighbors: Map<string, Set<string>>
  incidentEdges: Map<string, Set<string>>
  radii: Map<string, number>
  initialPositions: Map<string, { x: number; y: number }>
  hubNodeId: string | null
}

function truncateLabel(value: string, maxChars: number): string {
  return value.length <= maxChars ? value : `${value.slice(0, maxChars - 1)}…`
}

// The force layout settles once its cooling factor drops below this threshold, the same stopping point that d3's
// own simulation timer uses. At this decay rate the simulation reaches it after 103 ticks.
const FORCE_ALPHA_MIN = 0.001
const FORCE_ALPHA_DECAY = 0.065

type ForceBody = SimulationNodeDatum & { id: string }

/**
 * Runs the force layout to rest from the clustered seeds. The canvas then draws the settled graph once,
 * because drawing every simulation tick redraws every node and edge about a hundred times and keeps
 * the main thread busy for seconds on a graph of a few hundred elements.
 */
function settleForceLayout(
  nodes: readonly AnkoleGraphNode[],
  edges: readonly AnkoleGraphEdge[],
  nodeMap: ReadonlyMap<string, AnkoleGraphNode>,
  seeds: Map<string, { x: number; y: number }>,
  width: number,
  height: number
) {
  const bodies: ForceBody[] = nodes.map(node => ({
    id: node.id,
    ...(seeds.get(node.id) ?? { x: width / 2, y: height / 2 })
  }))
  const links: SimulationLinkDatum<ForceBody>[] = edges
    .filter(edge => nodeMap.has(edge.source) && nodeMap.has(edge.target) && edge.source !== edge.target)
    .map(edge => ({ source: edge.source, target: edge.target }))
  const simulation = forceSimulation(bodies)
    .stop()
    .alphaMin(FORCE_ALPHA_MIN)
    .alphaDecay(FORCE_ALPHA_DECAY)
    .velocityDecay(0.44)
    .force(
      'link',
      forceLink<ForceBody, SimulationLinkDatum<ForceBody>>(links)
        .id(body => body.id)
        .distance(126)
        .strength(0.34)
    )
    .force('charge', forceManyBody().strength(-230))
    .force('center', forceCenter(width / 2, height / 2))
    .force('collide', forceCollide(34).strength(0.9))
    .force('x', forceX(width / 2).strength(0.065))
    .force('y', forceY(height / 2).strength(0.065))
  while (simulation.alpha() >= FORCE_ALPHA_MIN) simulation.tick()
  for (const body of bodies) seeds.set(body.id, { x: body.x ?? width / 2, y: body.y ?? height / 2 })
}

/**
 * Computes degree centrality, 1-hop adjacency, visual node radii, and node coordinates so accessible
 * hit targets have viewport positions before the canvas finishes drawing. The force layout settles
 * here; the other layouts start from these coordinates and finish in `@antv/g6`.
 */
export function computeGraphTopology(
  nodes: readonly AnkoleGraphNode[],
  edges: readonly AnkoleGraphEdge[],
  layout: AnkoleGraphLayoutMode,
  width: number,
  height: number,
  focusCenterNodeId?: string | null
): AnkoleGraphTopology {
  const safeWidth = Math.max(320, width)
  const safeHeight = Math.max(260, height)
  const nodeMap = new Map(nodes.map(node => [node.id, node]))
  const degrees = new Map(nodes.map(node => [node.id, 0]))
  const inDegrees = new Map(nodes.map(node => [node.id, 0]))
  const neighbors = new Map(nodes.map(node => [node.id, new Set<string>()]))
  const incidentEdges = new Map(nodes.map(node => [node.id, new Set<string>()]))

  for (const edge of edges) {
    if (!nodeMap.has(edge.source) || !nodeMap.has(edge.target) || edge.source === edge.target) continue
    degrees.set(edge.source, (degrees.get(edge.source) ?? 0) + 1)
    degrees.set(edge.target, (degrees.get(edge.target) ?? 0) + 1)
    inDegrees.set(edge.target, (inDegrees.get(edge.target) ?? 0) + 1)
    neighbors.get(edge.source)!.add(edge.target)
    neighbors.get(edge.target)!.add(edge.source)
    incidentEdges.get(edge.source)!.add(edge.id)
    incidentEdges.get(edge.target)!.add(edge.id)
  }

  let hubNodeId: string | null = null
  let maxDegree = -1
  for (const node of nodes) {
    const degree = degrees.get(node.id) ?? 0
    if (degree > maxDegree) {
      maxDegree = degree
      hubNodeId = node.id
    }
  }

  const radii = new Map<string, number>()
  for (const node of nodes) {
    const metric = node.weight ?? degrees.get(node.id) ?? 0
    const radius =
      node.tier === 'hub'
        ? Math.round(14 + Math.min(8, Math.sqrt(metric) * 2))
        : Math.round(8.5 + Math.min(11.5, Math.sqrt(metric) * 2.6))
    radii.set(node.id, radius)
  }

  const initialPositions = new Map<string, { x: number; y: number }>()
  const centerX = safeWidth / 2
  const centerY = safeHeight / 2
  const padX = 56
  const padY = 48

  if (nodes.length === 0) {
    return { degrees, neighbors, incidentEdges, radii, initialPositions, hubNodeId }
  }

  if (nodes.length === 1) {
    initialPositions.set(nodes[0]!.id, { x: centerX, y: centerY })
    return { degrees, neighbors, incidentEdges, radii, initialPositions, hubNodeId }
  }

  if (layout === 'hierarchy') {
    const ranks = new Map<string, number>()
    const structuralOutgoing = new Map(nodes.map(node => [node.id, new Set<string>()]))
    const hasStructuralParent = new Set<string>()
    for (const node of nodes) {
      if (node.parentId && nodeMap.has(node.parentId) && node.parentId !== node.id) {
        structuralOutgoing.get(node.parentId)!.add(node.id)
        hasStructuralParent.add(node.id)
      }
    }
    for (const edge of edges) {
      if (
        edge.kind === 'hierarchy' &&
        nodeMap.has(edge.source) &&
        nodeMap.has(edge.target) &&
        edge.source !== edge.target
      ) {
        structuralOutgoing.get(edge.source)!.add(edge.target)
        hasStructuralParent.add(edge.target)
      }
    }

    const useStructuralTree = hasStructuralParent.size > 0
    const outgoing = useStructuralTree ? structuralOutgoing : new Map(nodes.map(node => [node.id, new Set<string>()]))
    if (!useStructuralTree) {
      for (const edge of edges) {
        if (nodeMap.has(edge.source) && nodeMap.has(edge.target) && edge.source !== edge.target) {
          outgoing.get(edge.source)!.add(edge.target)
        }
      }
    }

    const roots = useStructuralTree
      ? nodes.filter(node => node.tier === 'hub' || !hasStructuralParent.has(node.id))
      : nodes.filter(node => node.tier === 'hub' || (inDegrees.get(node.id) ?? 0) === 0)
    const queue = (roots.length > 0 ? roots : [nodes[0]!]).map(node => node.id)
    for (const id of queue) ranks.set(id, 0)

    const depthCap = Math.max(1, nodes.length - 1)
    for (let i = 0; i < queue.length; i++) {
      const current = queue[i]!
      const currentRank = ranks.get(current) ?? 0
      if (currentRank >= depthCap) continue
      const nextRank = currentRank + 1
      for (const child of outgoing.get(current) ?? []) {
        const existing = ranks.get(child)
        if (existing === undefined || nextRank > existing) {
          ranks.set(child, nextRank)
          queue.push(child)
        }
      }
    }

    for (const node of nodes) {
      if (!ranks.has(node.id)) ranks.set(node.id, 1)
    }

    const byRank = new Map<number, AnkoleGraphNode[]>()
    let maxRank = 0
    for (const node of nodes) {
      const rank = ranks.get(node.id) ?? 0
      maxRank = Math.max(maxRank, rank)
      const bucket = byRank.get(rank)
      if (bucket) bucket.push(node)
      else byRank.set(rank, [node])
    }

    const usableW = Math.max(120, safeWidth - padX * 2)
    const usableH = Math.max(120, safeHeight - padY * 2)
    for (const [rank, group] of byRank) {
      const y = maxRank === 0 ? centerY : padY + (rank / maxRank) * usableH
      group.forEach((node, idx) => {
        const x = group.length === 1 ? centerX : padX + ((idx + 0.5) / group.length) * usableW
        initialPositions.set(node.id, { x, y })
      })
    }
    return { degrees, neighbors, incidentEdges, radii, initialPositions, hubNodeId }
  }

  if (layout === 'radial') {
    const originId =
      focusCenterNodeId && nodeMap.has(focusCenterNodeId) ? focusCenterNodeId : (hubNodeId ?? nodes[0]!.id)
    const distances = new Map<string, number>([[originId, 0]])
    const queue = [originId]
    for (let i = 0; i < queue.length; i++) {
      const current = queue[i]!
      const nextDist = (distances.get(current) ?? 0) + 1
      for (const neighbor of neighbors.get(current) ?? []) {
        if (!distances.has(neighbor)) {
          distances.set(neighbor, nextDist)
          queue.push(neighbor)
        }
      }
    }
    let maxRing = 0
    for (const dist of distances.values()) maxRing = Math.max(maxRing, dist)
    const disconnectedRing = maxRing + 1
    for (const node of nodes) {
      if (!distances.has(node.id)) distances.set(node.id, disconnectedRing)
    }

    const rings = new Map<number, AnkoleGraphNode[]>()
    let outerRing = 0
    for (const node of nodes) {
      const ring = distances.get(node.id) ?? 0
      outerRing = Math.max(outerRing, ring)
      const bucket = rings.get(ring)
      if (bucket) bucket.push(node)
      else rings.set(ring, [node])
    }

    const maxRadius = Math.max(80, Math.min(safeWidth - padX * 2, safeHeight - padY * 2) * 0.45)
    for (const [ring, group] of rings) {
      if (ring === 0) {
        group.forEach((node, idx) => {
          initialPositions.set(node.id, { x: centerX + idx * 24, y: centerY })
        })
        continue
      }
      const radius = (ring / Math.max(1, outerRing)) * maxRadius
      group.forEach((node, idx) => {
        const angle = (idx / group.length) * Math.PI * 2 - Math.PI / 2
        initialPositions.set(node.id, {
          x: centerX + Math.cos(angle) * radius,
          y: centerY + Math.sin(angle) * radius
        })
      })
    }
    return { degrees, neighbors, incidentEdges, radii, initialPositions, hubNodeId }
  }

  // Clustered golden-angle spiral seeding for `force` and `combo` layouts.
  const groups = new Map<string, AnkoleGraphNode[]>()
  for (const node of nodes) {
    const key =
      node.tier === 'hub'
        ? node.id
        : (node.comboId ?? (node.parentId && nodeMap.has(node.parentId) ? node.parentId : (node.ramp ?? 'default')))
    const bucket = groups.get(key)
    if (bucket) bucket.push(node)
    else groups.set(key, [node])
  }

  const groupEntries = [...groups.entries()]
  const orbitX = Math.max(64, (safeWidth - padX * 2) * (groupEntries.length > 1 ? 0.3 : 0))
  const orbitY = Math.max(54, (safeHeight - padY * 2) * (groupEntries.length > 1 ? 0.28 : 0))
  const goldenAngle = Math.PI * (3 - Math.sqrt(5))

  groupEntries.forEach(([, members], clusterIndex) => {
    const clusterAngle = (clusterIndex / Math.max(1, groupEntries.length)) * Math.PI * 2 - Math.PI / 2
    const anchorX = groupEntries.length === 1 ? centerX : centerX + Math.cos(clusterAngle) * orbitX
    const anchorY = groupEntries.length === 1 ? centerY : centerY + Math.sin(clusterAngle) * orbitY

    const ordered = [...members].sort((left, right) => {
      if (left.tier !== right.tier) return left.tier === 'hub' ? -1 : 1
      return (degrees.get(right.id) ?? 0) - (degrees.get(left.id) ?? 0)
    })

    ordered.forEach((node, memberIndex) => {
      if (memberIndex === 0 && node.tier === 'hub') {
        initialPositions.set(node.id, { x: anchorX, y: anchorY })
        return
      }
      const step = Math.sqrt(memberIndex + 1) * 34
      const theta = memberIndex * goldenAngle + clusterAngle * 0.35
      const rawX = anchorX + Math.cos(theta) * step
      const rawY = anchorY + Math.sin(theta) * step
      initialPositions.set(node.id, {
        x: Math.min(safeWidth - padX, Math.max(padX, rawX)),
        y: Math.min(safeHeight - padY, Math.max(padY, rawY))
      })
    })
  })

  if (layout === 'force') settleForceLayout(nodes, edges, nodeMap, initialPositions, safeWidth, safeHeight)

  return { degrees, neighbors, incidentEdges, radii, initialPositions, hubNodeId }
}

export interface ProjectedAnchor {
  x: number
  y: number
  size: number
  visible: boolean
}

export interface GraphViewportReader {
  getZoom(): number
  getSize(): [number, number]
  hasNode(id: string): boolean
  getElementPosition(id: string): Point
  getViewportByCanvas(point: Point): Point
}

export function projectGraphAnchors(
  graph: GraphViewportReader,
  linkableNodes: readonly AnkoleGraphNode[],
  radii: ReadonlyMap<string, number>
): Map<string, ProjectedAnchor> {
  const rawZoom = graph.getZoom()
  const zoom = Number.isFinite(rawZoom) ? rawZoom : 1
  const [width, height] = graph.getSize()
  const next = new Map<string, ProjectedAnchor>()

  for (const node of linkableNodes) {
    if (!graph.hasNode(node.id)) continue
    try {
      const canvasPoint = graph.getElementPosition(node.id)
      const viewportPoint = graph.getViewportByCanvas(canvasPoint)
      const x = viewportPoint[0]
      const y = viewportPoint[1]
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue
      const radius = radii.get(node.id) ?? 10
      const diameter = Math.min(72, Math.max(24, Math.round(radius * 2 * zoom + 10)))
      const margin = diameter
      const visible = x >= -margin && x <= width + margin && y >= -margin && y <= height + margin
      next.set(node.id, { x, y, size: diameter, visible })
    } catch {
      // Ignore transient mid-update lookup before G6 commits a newly added node.
    }
  }
  return next
}

export interface BuildG6GraphSpecOptions {
  nodes: readonly AnkoleGraphNode[]
  edges: readonly AnkoleGraphEdge[]
  combos?: readonly AnkoleGraphCombo[]
  layout: AnkoleGraphLayoutMode
  width: number
  height: number
  palette: AnkoleCanvasThemePalette
  topology: AnkoleGraphTopology
  selectedNodeId?: string | null
  activeNodeId?: string | null
  focusCenterNodeId?: string | null
  showEdgeLabels?: boolean
  interactive?: boolean
}

// Edges that join the same two nodes fan out by this many pixels so each one stays visible.
const PARALLEL_EDGE_DISTANCE = 24

/**
 * Bends edges that join the same pair of nodes apart, in either direction, so none of them hides
 * another. An edge that runs opposite to the first edge of its pair takes the opposite sign, which
 * bends it to the other side because the offset follows each edge's own direction.
 */
function parallelEdgeOffsets(edges: readonly AnkoleGraphEdge[]): Map<string, number> {
  const groups = new Map<string, AnkoleGraphEdge[]>()
  for (const edge of edges) {
    const key = edge.source < edge.target ? `${edge.source}\u0000${edge.target}` : `${edge.target}\u0000${edge.source}`
    const group = groups.get(key)
    if (group) group.push(edge)
    else groups.set(key, [edge])
  }
  const offsets = new Map<string, number>()
  for (const group of groups.values()) {
    const first = group[0]!
    group.forEach((edge, index) => {
      if (group.length === 1) {
        offsets.set(edge.id, 0)
        return
      }
      const reversed = edge.source === first.target && edge.target === first.source
      const sign = (index % 2 === 0 ? 1 : -1) * (reversed ? -1 : 1)
      const step = PARALLEL_EDGE_DISTANCE * 2
      offsets.set(
        edge.id,
        group.length % 2 === 1
          ? sign * Math.ceil(index / 2) * step
          : sign * (Math.floor(index / 2) * step + PARALLEL_EDGE_DISTANCE)
      )
    })
  }
  return offsets
}

export function buildG6GraphSpec({
  nodes,
  edges,
  combos = [],
  layout,
  width,
  height,
  palette,
  topology,
  selectedNodeId = null,
  activeNodeId = null,
  focusCenterNodeId = null,
  showEdgeLabels = false,
  interactive = true
}: BuildG6GraphSpecOptions): {
  data: { nodes: NodeData[]; edges: EdgeData[]; combos: ComboData[] }
  layoutOptions: GraphOptions['layout']
  behaviors: GraphOptions['behaviors']
  transforms: GraphOptions['transforms']
} {
  const nodeById = new Map(nodes.map(node => [node.id, node]))
  const activeSet = activeNodeId && nodeById.has(activeNodeId) ? topology.neighbors.get(activeNodeId) : undefined
  const activeEdges = activeNodeId && nodeById.has(activeNodeId) ? topology.incidentEdges.get(activeNodeId) : undefined
  const hasSpotlight = Boolean(activeNodeId && nodeById.has(activeNodeId))
  const activeComboIds = layout === 'combo' ? new Set(combos.map(combo => combo.id)) : new Set<string>()

  const g6Combos: ComboData[] =
    layout === 'combo'
      ? combos.map(combo => {
          const rampColors = palette.ramps[combo.ramp ?? 'gray']
          return {
            id: combo.id,
            ...(combo.parentId && activeComboIds.has(combo.parentId) ? { combo: combo.parentId } : {}),
            style: {
              type: 'rect',
              radius: 12,
              padding: [28, 22, 20, 22],
              fill: rampColors.subtle,
              fillOpacity: palette.isDark ? 0.34 : 0.62,
              stroke: rampColors.stroke,
              strokeOpacity: 0.45,
              lineWidth: 1.25,
              lineDash: [5, 4],
              labelText: combo.label,
              labelPlacement: 'top',
              labelFill: rampColors.text,
              labelFontSize: 12,
              labelFontWeight: 600,
              labelFontFamily: palette.fontSans
            }
          }
        })
      : []

  const g6Nodes: NodeData[] = nodes.map(node => {
    const rampColors = palette.ramps[node.ramp ?? 'blue']
    const radius = topology.radii.get(node.id) ?? 10
    const seed = topology.initialPositions.get(node.id) ?? { x: width / 2, y: height / 2 }
    const isSelected = selectedNodeId === node.id
    const isFocused = activeNodeId === node.id
    const isNeighbor = Boolean(activeSet?.has(node.id))
    const isDimmed = hasSpotlight && !isFocused && !isNeighbor
    const shape: AnkoleGraphNodeShape = node.shape ?? (node.tier === 'hub' ? 'diamond' : 'circle')
    const size: number | [number, number] =
      shape === 'rect' ? [Math.max(92, radius * 5), Math.max(30, radius * 2.2)] : radius * 2

    return {
      id: node.id,
      type: shape,
      ...(layout === 'combo' && node.comboId && activeComboIds.has(node.comboId) ? { combo: node.comboId } : {}),
      data: {
        tier: node.tier ?? 'object',
        degree: topology.degrees.get(node.id) ?? 0
      },
      style: {
        x: seed.x,
        y: seed.y,
        size,
        ...(shape === 'rect' ? { radius: 6 } : {}),
        fill: rampColors.fill,
        fillOpacity: isDimmed ? 0.2 : node.tier === 'hub' ? 0.96 : 0.9,
        stroke: isSelected || isFocused ? palette.foreground : rampColors.stroke,
        strokeOpacity: isDimmed ? 0.22 : 0.95,
        lineWidth: isSelected ? 2.8 : isFocused ? 2.4 : node.tier === 'hub' ? 2 : 1.5,
        halo: isSelected || isFocused,
        haloStroke: rampColors.fill,
        haloStrokeOpacity: isSelected ? 0.34 : 0.24,
        haloLineWidth: isSelected ? 9 : 7,
        cursor: interactive ? 'pointer' : 'default',
        zIndex: isSelected || isFocused ? 30 : isNeighbor ? 20 : node.tier === 'hub' ? 12 : 5,
        labelText: truncateLabel(node.label, node.tier === 'hub' ? 24 : 20),
        labelPlacement: 'bottom',
        labelOffsetY: 5,
        labelFill: isDimmed ? palette.fgTertiary : palette.foreground,
        labelOpacity: isDimmed ? 0.38 : 1,
        labelFontSize: node.tier === 'hub' ? 12.5 : 11.5,
        labelFontWeight: node.tier === 'hub' || isSelected || isFocused ? 600 : 450,
        labelFontFamily: palette.fontSans,
        labelHalo: true,
        labelHaloFill: palette.background,
        labelHaloLineWidth: 3.5
      }
    }
  })

  const drawnEdges = edges.filter(
    edge => nodeById.has(edge.source) && nodeById.has(edge.target) && edge.source !== edge.target
  )
  const curveOffsets = parallelEdgeOffsets(drawnEdges)
  const g6Edges: EdgeData[] = drawnEdges.map(edge => {
    const sourceNode = nodeById.get(edge.source)
    const rampColors = palette.ramps[edge.ramp ?? sourceNode?.ramp ?? 'gray']
    const isHighlighted = Boolean(activeEdges?.has(edge.id))
    const isDimmed = hasSpotlight && !isHighlighted
    const showLabel = Boolean(edge.label && (showEdgeLabels || isHighlighted))

    return {
      id: edge.id,
      source: edge.source,
      target: edge.target,
      type: 'quadratic',
      data: {
        kind: edge.kind ?? 'relation'
      },
      style: {
        curveOffset: curveOffsets.get(edge.id) ?? 0,
        stroke: rampColors.fill,
        strokeOpacity: isDimmed ? 0.08 : isHighlighted ? 0.92 : edge.kind === 'hierarchy' ? 0.38 : 0.56,
        lineWidth: isHighlighted ? 2.2 : edge.kind === 'hierarchy' ? 1.2 : 1.5,
        ...(edge.dashed ? { lineDash: [4, 4] } : {}),
        endArrow: true,
        endArrowSize: isHighlighted ? 7 : 5.5,
        endArrowType: 'vee',
        zIndex: isHighlighted ? 25 : 1,
        ...(showLabel
          ? {
              labelText: edge.label,
              labelFontSize: 10,
              labelFontFamily: palette.fontMono,
              labelFill: isHighlighted ? palette.foreground : palette.fgSecondary,
              labelBackground: true,
              labelBackgroundFill: palette.background,
              labelBackgroundOpacity: 0.88,
              labelBackgroundRadius: 3,
              labelPadding: [1, 4]
            }
          : { labelText: '' })
      }
    }
  })

  // The force layout settles in `computeGraphTopology`, so its nodes already carry final coordinates and
  // `@antv/g6` only draws them; the remaining layouts run inside `@antv/g6`.
  let layoutOptions: GraphOptions['layout']
  if (layout === 'hierarchy') {
    layoutOptions = {
      type: 'antv-dagre',
      rankdir: 'TB',
      nodesep: 32,
      ranksep: 64,
      controlPoints: true
    }
  } else if (layout === 'combo') {
    layoutOptions = {
      type: 'combo-combined',
      comboPadding: 24,
      spacing: 26
    }
  } else if (layout === 'radial') {
    const originId =
      focusCenterNodeId && nodeById.has(focusCenterNodeId) ? focusCenterNodeId : (topology.hubNodeId ?? nodes[0]?.id)
    layoutOptions = {
      type: 'radial',
      unitRadius: 104,
      linkDistance: 116,
      preventOverlap: true,
      nodeSize: 52,
      maxPreventOverlapIteration: 200,
      ...(originId ? { focusNode: originId } : {})
    }
  }

  const behaviors: GraphOptions['behaviors'] = interactive
    ? [
        'drag-canvas',
        { type: 'zoom-canvas', sensitivity: 1.15 },
        'drag-element',
        ...(layout === 'combo' ? [{ type: 'collapse-expand', trigger: 'dblclick' as const }] : [])
      ]
    : []

  return {
    data: { nodes: g6Nodes, edges: g6Edges, combos: g6Combos },
    layoutOptions,
    behaviors,
    // Collapsing a category combo redirects its members' edges to the combo, so edges that join different members
    // to one outside node become parallel only then. G6's transform offsets them by their resolved ends on each
    // draw; the other layouts cannot collapse, and the offsets computed above stay correct for them.
    transforms:
      layout === 'combo'
        ? [{ type: 'process-parallel-edges', key: 'parallel-edges', distance: PARALLEL_EDGE_DISTANCE }]
        : []
  }
}
