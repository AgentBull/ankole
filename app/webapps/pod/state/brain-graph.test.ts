import { describe, expect, test } from 'bun:test'
import { buildBrainOntologyGraph, resolveBrainColorRamp } from './brain-graph'

const CATEGORIES = [
  { id: 'cat-people', name: 'people', can_edit: false, entity_type: 'person', primitive: 'entity' },
  { id: 'cat-agents', name: 'agents', can_edit: false, entity_type: 'agent', primitive: 'entity' },
  { id: 'cat-companies', name: 'companies', can_edit: true, entity_type: 'company', primitive: 'entity' },
  { id: 'cat-analyses', name: 'analyses', can_edit: true, entity_type: 'analysis', primitive: 'concept' }
]

const NODES = [
  { id: 'p-boris', title: 'Boris', slug: 'people/boris', type: 'person', parent_id: 'cat-people' },
  {
    id: 'a-boris-pa',
    title: 'boris_assistant',
    slug: 'agents/boris_assistant',
    type: 'agent',
    subtype: 'personal_assistant',
    parent_id: 'cat-agents'
  },
  { id: 'c-acme', title: 'Acme Corp', slug: 'companies/acme', type: 'company', parent_id: 'cat-companies' },
  {
    id: 'c-acme-cloud',
    title: 'Acme Cloud Division',
    slug: 'companies/acme/cloud',
    type: 'project',
    parent_id: 'c-acme'
  },
  {
    id: 'an-q3',
    title: 'Q3 Cloud Assessment',
    slug: 'analyses/q3-cloud',
    type: 'analysis',
    parent_id: 'cat-analyses'
  }
]

const LINKS = [
  { from_page_id: 'c-acme', to_page_id: 'c-acme-cloud', link_type: 'contains', relation_kind: 'hierarchy' },
  { from_page_id: 'a-boris-pa', to_page_id: 'p-boris', link_type: 'assists', relation_kind: 'ownership' },
  { from_page_id: 'p-boris', to_page_id: 'c-acme', link_type: 'advises', relation_kind: 'semantic' },
  { from_page_id: 'an-q3', to_page_id: 'c-acme-cloud', link_type: 'evidences', relation_kind: 'evidence' },
  { from_page_id: 'an-q3', to_page_id: 'c-acme', link_type: 'references', relation_kind: 'reference' }
]

describe('buildBrainOntologyGraph', () => {
  test('maps ontology primitives and entity types to semantic color ramps', () => {
    expect(resolveBrainColorRamp('agent', 'entity')).toBe('brand')
    expect(resolveBrainColorRamp('person', 'entity')).toBe('teal')
    expect(resolveBrainColorRamp('company', 'entity')).toBe('blue')
    expect(resolveBrainColorRamp('analysis', 'concept')).toBe('purple')
    expect(resolveBrainColorRamp('custom_record', 'temporal')).toBe('orange')
  })

  test('projects category hubs, multi-level parent-child hierarchy, and typed directed relations', () => {
    const graph = buildBrainOntologyGraph({
      categories: CATEGORIES,
      nodes: NODES,
      links: LINKS,
      layout: 'force',
      includeCategoryHubs: true
    })

    // 4 populated category hubs + 5 object nodes
    expect(graph.visibleObjects).toHaveLength(5)
    expect(graph.nodes).toHaveLength(9)

    // Only object nodes expose navigable `href` links; category hubs remain non-link structural anchors.
    const linkable = graph.nodes.filter(node => Boolean(node.href))
    expect(linkable).toHaveLength(5)

    // Nested child points to its parent object (`c-acme`), while root `c-acme` points to `hub:cat:cat-companies`.
    const acmeNode = graph.nodes.find(node => node.id === 'c-acme')
    const cloudNode = graph.nodes.find(node => node.id === 'c-acme-cloud')
    expect(acmeNode?.parentId).toBe('hub:cat:cat-companies')
    expect(cloudNode?.parentId).toBe('c-acme')

    // Evidence and reference edges are dashed; ownership and hierarchy edges are solid.
    const ownershipEdge = graph.edges.find(edge => edge.label === 'assists')
    const evidenceEdge = graph.edges.find(edge => edge.label === 'evidences')
    expect(ownershipEdge?.dashed).toBeFalsy()
    expect(ownershipEdge?.ramp).toBe('brand')
    expect(evidenceEdge?.dashed).toBe(true)
    expect(evidenceEdge?.ramp).toBe('orange')
  })

  test('switches to category combo containers in combo layout without duplicating hub diamonds', () => {
    const graph = buildBrainOntologyGraph({
      categories: CATEGORIES,
      nodes: NODES,
      links: LINKS,
      layout: 'combo',
      includeCategoryHubs: true
    })

    expect(graph.combos).toHaveLength(4)
    expect(graph.nodes).toHaveLength(5)
    expect(graph.nodes.find(node => node.id === 'c-acme-cloud')?.comboId).toBe('combo:cat:cat-companies')
  })

  test('preserves toggleable layer facets and bridges hierarchy when an intermediate entity type is hidden', () => {
    const graph = buildBrainOntologyGraph({
      categories: CATEGORIES,
      nodes: NODES,
      links: LINKS,
      hiddenEntityTypes: new Set(['company']),
      hiddenRelationKinds: new Set(['evidence'])
    })

    // `company` remains listed in `entityLayers` with `visible: false` so the user can turn it back on.
    const companyLayer = graph.entityLayers.find(layer => layer.type === 'company')
    expect(companyLayer?.count).toBe(1)
    expect(companyLayer?.visible).toBe(false)
    expect(graph.visibleObjects.some(node => node.id === 'c-acme')).toBe(false)

    // With `c-acme` hidden, `c-acme-cloud` bridges cleanly to `hub:cat:cat-companies` instead of becoming orphaned.
    const cloudNode = graph.nodes.find(node => node.id === 'c-acme-cloud')
    expect(cloudNode?.parentId).toBe('hub:cat:cat-companies')

    // `evidence` remains listed in `relationLayers` with `visible: false` while hidden from rendered edges.
    expect(graph.relationLayers.find(layer => layer.kind === 'evidence')?.visible).toBe(false)
    expect(graph.edges.some(edge => edge.label === 'evidences')).toBe(false)
  })

  test('inspects both category hubs and nested Brain objects with lineage, children, and peer relations', () => {
    const graph = buildBrainOntologyGraph({
      categories: CATEGORIES,
      nodes: NODES,
      links: LINKS
    })

    const hubInfo = graph.inspect('hub:cat:cat-companies')
    expect(hubInfo?.kind).toBe('hub')
    if (hubInfo?.kind === 'hub') {
      expect(hubInfo.category.name).toBe('companies')
      expect(hubInfo.members.map(m => m.id)).toEqual(['c-acme', 'c-acme-cloud'])
    }

    const cloudInfo = graph.inspect('c-acme-cloud')
    expect(cloudInfo?.kind).toBe('object')
    if (cloudInfo?.kind === 'object') {
      expect(cloudInfo.category?.name).toBe('companies')
      expect(cloudInfo.ancestors.map(a => a.id)).toEqual(['c-acme'])
      expect(cloudInfo.relations).toHaveLength(1)
      expect(cloudInfo.relations[0]?.linkType).toBe('evidences')
      expect(cloudInfo.relations[0]?.direction).toBe('incoming')
    }

    const acmeInfo = graph.inspect('c-acme')
    if (acmeInfo?.kind === 'object') {
      expect(acmeInfo.children.map(c => c.id)).toEqual(['c-acme-cloud'])
      expect(acmeInfo.relations.map(r => r.linkType).sort()).toEqual(['advises', 'references'])
    }
  })
})
