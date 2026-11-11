import type {
  AnkoleGraphColorRamp,
  AnkoleGraphCombo,
  AnkoleGraphEdge,
  AnkoleGraphLayoutMode,
  AnkoleGraphNode
} from '@ankole/uikit/components/graph'

interface BrainOntologyCategory {
  id: string
  name: string
  can_edit: boolean
  entity_type: string
  primitive: string
}

export interface BrainOntologyNode {
  id: string
  title: string
  slug: string
  type: string
  subtype?: string | null
  parent_id?: string | null
}

export type BrainRelationKind = 'hierarchy' | 'ownership' | 'semantic' | 'reference' | 'evidence'

interface BrainOntologyLink {
  from_page_id: string
  to_page_id: string
  link_type: string
  relation_kind: string
}

export interface BrainEntityLayer {
  type: string
  count: number
  ramp: AnkoleGraphColorRamp
  visible: boolean
}

export interface BrainRelationLayer {
  kind: BrainRelationKind
  count: number
  ramp: AnkoleGraphColorRamp
  visible: boolean
}

interface BrainInspectorRelation {
  direction: 'outgoing' | 'incoming'
  linkType: string
  relationKind: BrainRelationKind
  peer: BrainOntologyNode
  ramp: AnkoleGraphColorRamp
}

export type BrainInspectorSelection =
  | {
      kind: 'hub'
      hubId: string
      category: BrainOntologyCategory
      ramp: AnkoleGraphColorRamp
      members: BrainOntologyNode[]
    }
  | {
      kind: 'object'
      object: BrainOntologyNode
      category: BrainOntologyCategory | undefined
      ramp: AnkoleGraphColorRamp
      ancestors: BrainOntologyNode[]
      children: BrainOntologyNode[]
      relations: BrainInspectorRelation[]
    }

interface BuildBrainOntologyGraphOptions {
  categories: readonly BrainOntologyCategory[]
  nodes: readonly BrainOntologyNode[]
  links: readonly BrainOntologyLink[]
  categoryFilter?: string
  search?: string
  layout?: AnkoleGraphLayoutMode
  includeCategoryHubs?: boolean
  hiddenEntityTypes?: ReadonlySet<string>
  hiddenRelationKinds?: ReadonlySet<BrainRelationKind>
  focusSlugs?: ReadonlySet<string>
}

interface BrainOntologyGraphProjection {
  nodes: AnkoleGraphNode[]
  edges: AnkoleGraphEdge[]
  combos: AnkoleGraphCombo[]
  visibleObjects: BrainOntologyNode[]
  entityLayers: BrainEntityLayer[]
  relationLayers: BrainRelationLayer[]
  focusedNodeIds: ReadonlySet<string> | null
  primaryFocusNodeId: string | null
  inspect: (nodeId: string | null) => BrainInspectorSelection | null
}

const HUB_PREFIX = 'hub:cat:'
const COMBO_PREFIX = 'combo:cat:'

const RELATION_ORDER: readonly BrainRelationKind[] = ['hierarchy', 'ownership', 'semantic', 'reference', 'evidence']

const ENTITY_TYPE_RAMPS: Readonly<Record<string, AnkoleGraphColorRamp>> = {
  agent: 'brand',
  agents: 'brand',
  person: 'teal',
  people: 'teal',
  company: 'blue',
  companies: 'blue',
  organization: 'blue',
  organizations: 'blue',
  project: 'cyan',
  projects: 'cyan',
  analysis: 'purple',
  analyses: 'purple',
  synthesis: 'purple',
  event: 'orange',
  events: 'orange',
  document: 'green',
  documents: 'green',
  source: 'green',
  sources: 'green',
  file: 'green',
  concept: 'magenta',
  concepts: 'magenta',
  topic: 'magenta',
  topics: 'magenta',
  note: 'yellow',
  notes: 'yellow'
}

const PRIMITIVE_RAMPS: Readonly<Record<string, AnkoleGraphColorRamp>> = {
  entity: 'blue',
  media: 'green',
  temporal: 'orange',
  annotation: 'yellow',
  concept: 'purple'
}

export function resolveBrainColorRamp(entityType: string, primitive?: string | null): AnkoleGraphColorRamp {
  const normalizedType = entityType.trim().toLowerCase()
  const byType = ENTITY_TYPE_RAMPS[normalizedType]
  if (byType) return byType
  if (primitive) {
    const byPrimitive = PRIMITIVE_RAMPS[primitive.trim().toLowerCase()]
    if (byPrimitive) return byPrimitive
  }
  return 'blue'
}

function normalizeRelationKind(raw: string): BrainRelationKind {
  switch (raw) {
    case 'hierarchy':
    case 'ownership':
    case 'semantic':
    case 'reference':
    case 'evidence':
      return raw
    default:
      return 'semantic'
  }
}

function resolveRelationRamp(kind: BrainRelationKind, sourceRamp: AnkoleGraphColorRamp): AnkoleGraphColorRamp {
  switch (kind) {
    case 'hierarchy':
      return sourceRamp
    case 'ownership':
      return 'brand'
    case 'semantic':
      return 'purple'
    case 'reference':
      return 'cyan'
    case 'evidence':
      return 'orange'
  }
}

function resolveNodeCategory(
  node: BrainOntologyNode,
  categoriesById: ReadonlyMap<string, BrainOntologyCategory>,
  categoriesByName: ReadonlyMap<string, BrainOntologyCategory>,
  allNodesById: ReadonlyMap<string, BrainOntologyNode>
): BrainOntologyCategory | undefined {
  const seen = new Set<string>([node.id])
  let cursor: string | null | undefined = node.parent_id
  while (cursor && !seen.has(cursor)) {
    const directCategory = categoriesById.get(cursor)
    if (directCategory) return directCategory
    seen.add(cursor)
    cursor = allNodesById.get(cursor)?.parent_id
  }
  const rootSegment = node.slug.split('/')[0]
  return rootSegment ? categoriesByName.get(rootSegment) : undefined
}

function resolveVisibleAncestorObjectId(
  node: BrainOntologyNode,
  visibleById: ReadonlyMap<string, BrainOntologyNode>,
  allNodesById: ReadonlyMap<string, BrainOntologyNode>
): string | undefined {
  const seen = new Set<string>([node.id])
  let cursor: string | null | undefined = node.parent_id
  while (cursor && !seen.has(cursor)) {
    if (visibleById.has(cursor)) return cursor
    seen.add(cursor)
    cursor = allNodesById.get(cursor)?.parent_id
  }
  return undefined
}

function collectObjectAncestors(
  node: BrainOntologyNode,
  allNodesById: ReadonlyMap<string, BrainOntologyNode>
): BrainOntologyNode[] {
  const chain: BrainOntologyNode[] = []
  const seen = new Set<string>([node.id])
  let cursor: string | null | undefined = node.parent_id
  while (cursor && !seen.has(cursor)) {
    const parent = allNodesById.get(cursor)
    if (!parent) break
    chain.unshift(parent)
    seen.add(cursor)
    cursor = parent.parent_id
  }
  return chain
}

/**
 * Projects the control-plane Brain ontology response into `<AnkoleGraph />` nodes,
 * hierarchical/semantic/ownership/evidence edges, category combos, facet layers, and inspector lookups.
 */
export function buildBrainOntologyGraph({
  categories,
  nodes,
  links,
  categoryFilter = 'all',
  search = '',
  layout = 'force',
  includeCategoryHubs = true,
  hiddenEntityTypes = new Set<string>(),
  hiddenRelationKinds = new Set<BrainRelationKind>(),
  focusSlugs
}: BuildBrainOntologyGraphOptions): BrainOntologyGraphProjection {
  const categoriesById = new Map(categories.map(cat => [cat.id, cat]))
  const categoriesByName = new Map(categories.map(cat => [cat.name, cat]))
  const allNodesById = new Map(nodes.map(node => [node.id, node]))
  const categoryByNodeId = new Map<string, BrainOntologyCategory>()
  for (const node of nodes) {
    const cat = resolveNodeCategory(node, categoriesById, categoriesByName, allNodesById)
    if (cat) categoryByNodeId.set(node.id, cat)
  }

  const normalizedQuery = search.trim().toLocaleLowerCase()
  const matchedObjects = nodes.filter(node => {
    const cat = categoryByNodeId.get(node.id)
    const matchesCategory =
      categoryFilter === 'all' ||
      cat?.name === categoryFilter ||
      node.slug === categoryFilter ||
      node.slug.startsWith(`${categoryFilter}/`)
    if (!matchesCategory) return false
    if (!normalizedQuery) return true
    const haystack = `${node.title} ${node.slug} ${node.type} ${node.subtype ?? ''}`.toLocaleLowerCase()
    return haystack.includes(normalizedQuery)
  })

  // Facet counts reflect matched objects before entity-layer toggles so hidden layers stay toggleable.
  const entityCountByType = new Map<string, { count: number; primitive?: string }>()
  for (const node of matchedObjects) {
    const cat = categoryByNodeId.get(node.id)
    const entry = entityCountByType.get(node.type)
    if (entry) entry.count += 1
    else entityCountByType.set(node.type, { count: 1, primitive: cat?.primitive })
  }
  const entityLayers: BrainEntityLayer[] = [...entityCountByType.entries()]
    .sort((a, b) => b[1].count - a[1].count || a[0].localeCompare(b[0]))
    .map(([type, info]) => ({
      type,
      count: info.count,
      ramp: resolveBrainColorRamp(type, info.primitive),
      visible: !hiddenEntityTypes.has(type)
    }))

  const visibleObjects = matchedObjects.filter(node => !hiddenEntityTypes.has(node.type))
  const visibleById = new Map(visibleObjects.map(node => [node.id, node]))

  let focusedNodeIds: Set<string> | null = null
  let primaryFocusNodeId: string | null = null
  const seedNodeIds = new Set<string>()
  if (focusSlugs && focusSlugs.size > 0) {
    for (const node of visibleObjects) {
      if (focusSlugs.has(node.slug)) {
        seedNodeIds.add(node.id)
        if (!primaryFocusNodeId || node.slug.startsWith('people/')) {
          primaryFocusNodeId = node.id
        }
      }
    }
    if (seedNodeIds.size > 0) {
      focusedNodeIds = new Set<string>(seedNodeIds)
      for (const link of links) {
        if (seedNodeIds.has(link.from_page_id) && visibleById.has(link.to_page_id)) {
          focusedNodeIds.add(link.to_page_id)
        }
        if (seedNodeIds.has(link.to_page_id) && visibleById.has(link.from_page_id)) {
          focusedNodeIds.add(link.from_page_id)
        }
      }
      for (const node of visibleObjects) {
        if (seedNodeIds.has(node.id) && node.parent_id && visibleById.has(node.parent_id)) {
          focusedNodeIds.add(node.parent_id)
        }
        if (node.parent_id && seedNodeIds.has(node.parent_id)) {
          focusedNodeIds.add(node.id)
        }
      }
    }
  }

  const populatedCategories = new Map<string, BrainOntologyCategory>()
  for (const node of visibleObjects) {
    const cat = categoryByNodeId.get(node.id)
    if (cat) populatedCategories.set(cat.id, cat)
  }

  const emitHubs = includeCategoryHubs && layout !== 'combo' && visibleObjects.length > 0
  const combos: AnkoleGraphCombo[] =
    layout === 'combo'
      ? [...populatedCategories.values()].map(cat => ({
          id: `${COMBO_PREFIX}${cat.id}`,
          label: cat.name,
          ramp: resolveBrainColorRamp(cat.entity_type || cat.name, cat.primitive)
        }))
      : []

  const graphNodes: AnkoleGraphNode[] = []
  const nodeRampById = new Map<string, AnkoleGraphColorRamp>()
  const membersByCategoryId = new Map<string, BrainOntologyNode[]>()

  for (const node of visibleObjects) {
    const cat = categoryByNodeId.get(node.id)
    if (cat) {
      const bucket = membersByCategoryId.get(cat.id)
      if (bucket) bucket.push(node)
      else membersByCategoryId.set(cat.id, [node])
    }
  }

  if (emitHubs) {
    for (const cat of populatedCategories.values()) {
      const hubId = `${HUB_PREFIX}${cat.id}`
      const baseRamp = resolveBrainColorRamp(cat.entity_type || cat.name, cat.primitive)
      const members = membersByCategoryId.get(cat.id) ?? []
      const count = members.length
      const hubFocused = !focusedNodeIds || members.some(m => focusedNodeIds.has(m.id))
      const ramp: AnkoleGraphColorRamp = hubFocused ? baseRamp : 'gray'
      if (focusedNodeIds && hubFocused) focusedNodeIds.add(hubId)
      nodeRampById.set(hubId, ramp)
      graphNodes.push({
        id: hubId,
        label: cat.name,
        subtitle: `${cat.entity_type} · ${count}`,
        tier: 'hub',
        shape: 'diamond',
        ramp,
        weight: count + 2
      })
    }
  }

  const candidateEdges: Array<{
    edge: AnkoleGraphEdge
    relationKind: BrainRelationKind
  }> = []
  const seenEdgeKeys = new Set<string>()

  for (const node of visibleObjects) {
    const cat = categoryByNodeId.get(node.id)
    const baseRamp = resolveBrainColorRamp(node.type, cat?.primitive)
    const isFocused = !focusedNodeIds || focusedNodeIds.has(node.id)
    const ramp: AnkoleGraphColorRamp = isFocused ? baseRamp : 'gray'
    nodeRampById.set(node.id, ramp)

    const visibleObjectParentId = resolveVisibleAncestorObjectId(node, visibleById, allNodesById)
    const hubParentId = emitHubs && cat ? `${HUB_PREFIX}${cat.id}` : undefined
    const effectiveParentId = visibleObjectParentId ?? hubParentId

    graphNodes.push({
      id: node.id,
      label: node.title,
      subtitle: node.subtype ? `${node.type} · ${node.subtype}` : node.type,
      href: `/meta/brain/${node.id}`,
      tier: 'object',
      shape: 'circle',
      ramp,
      weight: seedNodeIds.has(node.id) ? 4 : undefined,
      parentId: effectiveParentId,
      comboId: layout === 'combo' && cat ? `${COMBO_PREFIX}${cat.id}` : undefined
    })

    if (!visibleObjectParentId && hubParentId) {
      const key = `${hubParentId}->${node.id}:categorizes`
      seenEdgeKeys.add(key)
      candidateEdges.push({
        relationKind: 'hierarchy',
        edge: {
          id: `edge:${key}`,
          source: hubParentId,
          target: node.id,
          kind: 'hierarchy',
          ramp
        }
      })
    } else if (visibleObjectParentId) {
      // Ensure ancestor bridge edge exists even when an intermediate object was filtered out.
      const key = `${visibleObjectParentId}->${node.id}:contains`
      seenEdgeKeys.add(key)
      candidateEdges.push({
        relationKind: 'hierarchy',
        edge: {
          id: `edge:${key}`,
          source: visibleObjectParentId,
          target: node.id,
          label: 'contains',
          kind: 'hierarchy',
          ramp: nodeRampById.get(visibleObjectParentId) ?? ramp
        }
      })
    }
  }

  for (const link of links) {
    if (!visibleById.has(link.from_page_id) || !visibleById.has(link.to_page_id)) continue
    if (link.from_page_id === link.to_page_id) continue
    const relationKind = normalizeRelationKind(link.relation_kind)
    const key = `${link.from_page_id}->${link.to_page_id}:${link.link_type}`
    if (seenEdgeKeys.has(key)) continue
    seenEdgeKeys.add(key)

    const sourceRamp = nodeRampById.get(link.from_page_id) ?? 'blue'
    const bothFocused =
      !focusedNodeIds || (focusedNodeIds.has(link.from_page_id) && focusedNodeIds.has(link.to_page_id))
    const edgeRamp: AnkoleGraphColorRamp = bothFocused ? resolveRelationRamp(relationKind, sourceRamp) : 'gray'
    candidateEdges.push({
      relationKind,
      edge: {
        id: `edge:${key}`,
        source: link.from_page_id,
        target: link.to_page_id,
        label: link.link_type,
        kind: relationKind === 'hierarchy' ? 'hierarchy' : 'relation',
        dashed: relationKind === 'reference' || relationKind === 'evidence',
        ramp: edgeRamp
      }
    })
  }

  const relationCounts = new Map<BrainRelationKind, number>()
  for (const item of candidateEdges) {
    relationCounts.set(item.relationKind, (relationCounts.get(item.relationKind) ?? 0) + 1)
  }
  const relationLayers: BrainRelationLayer[] = RELATION_ORDER.filter(kind => (relationCounts.get(kind) ?? 0) > 0).map(
    kind => ({
      kind,
      count: relationCounts.get(kind) ?? 0,
      ramp: resolveRelationRamp(kind, 'blue'),
      visible: !hiddenRelationKinds.has(kind)
    })
  )

  const edges = candidateEdges.filter(item => !hiddenRelationKinds.has(item.relationKind)).map(item => item.edge)

  const inspect = (nodeId: string | null): BrainInspectorSelection | null => {
    if (!nodeId) return null
    if (nodeId.startsWith(HUB_PREFIX)) {
      const catId = nodeId.slice(HUB_PREFIX.length)
      const cat = populatedCategories.get(catId) ?? categoriesById.get(catId)
      if (!cat) return null
      return {
        kind: 'hub',
        hubId: nodeId,
        category: cat,
        ramp: resolveBrainColorRamp(cat.entity_type || cat.name, cat.primitive),
        members: membersByCategoryId.get(cat.id) ?? []
      }
    }

    const target = visibleById.get(nodeId) ?? allNodesById.get(nodeId)
    if (!target) return null
    const cat = categoryByNodeId.get(target.id)
    const ramp = resolveBrainColorRamp(target.type, cat?.primitive)
    const ancestors = collectObjectAncestors(target, allNodesById)
    const children = nodes.filter(candidate => candidate.parent_id === target.id)

    const relations: BrainInspectorRelation[] = []
    for (const link of links) {
      const kind = normalizeRelationKind(link.relation_kind)
      if (kind === 'hierarchy') continue
      if (link.from_page_id === target.id) {
        const peer = allNodesById.get(link.to_page_id)
        if (peer) {
          relations.push({
            direction: 'outgoing',
            linkType: link.link_type,
            relationKind: kind,
            peer,
            ramp: resolveRelationRamp(kind, ramp)
          })
        }
      } else if (link.to_page_id === target.id) {
        const peer = allNodesById.get(link.from_page_id)
        if (peer) {
          relations.push({
            direction: 'incoming',
            linkType: link.link_type,
            relationKind: kind,
            peer,
            ramp: resolveRelationRamp(kind, ramp)
          })
        }
      }
    }

    return {
      kind: 'object',
      object: target,
      category: cat,
      ramp,
      ancestors,
      children,
      relations
    }
  }

  return {
    nodes: graphNodes,
    edges,
    combos,
    visibleObjects,
    entityLayers,
    relationLayers,
    focusedNodeIds,
    primaryFocusNodeId,
    inspect
  }
}
