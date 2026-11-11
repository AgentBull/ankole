import {
  Button,
  buttonVariants,
  cn,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Toggle,
  ToggleGroup,
  ToggleGroupItem
} from '@ankole/uikit'
import {
  AnkoleGraph,
  useCanvasThemePalette,
  type AnkoleCanvasThemePalette,
  type AnkoleGraphHandle,
  type AnkoleGraphLayoutMode
} from '@ankole/uikit/components/graph'
import {
  AddRegular,
  ArrowUpRightRegular,
  CompassNorthwestRegular,
  DataScatterRegular,
  DismissRegular,
  FullScreenMaximizeRegular,
  OrganizationHorizontalRegular,
  StackRegular,
  TagRegular,
  TargetRegular,
  TextBulletListTreeRegular,
  ZoomInRegular,
  ZoomOutRegular
} from '@ankole/uikit/icons'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useNavigate } from '@tanstack/react-router'
import { useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from '../common/router'
import { PageContentList } from './content-list'
import { ContentError } from './content-primitives'
import { metaBrainQuery, metaKeys } from './meta-api'
import { usePageCreation } from './page-create-menu'
import { PageRoute } from './page-workspace'
import {
  buildBrainOntologyGraph,
  resolveBrainColorRamp,
  type BrainEntityLayer,
  type BrainInspectorSelection,
  type BrainOntologyNode,
  type BrainRelationKind,
  type BrainRelationLayer
} from './state/brain-graph'
import { usePagesMetadata } from './use-page-metadata'

const LAYOUT_OPTIONS: readonly {
  mode: AnkoleGraphLayoutMode
  labelKey: 'layout_force' | 'layout_hierarchy' | 'layout_combo' | 'layout_radial'
  Icon: typeof OrganizationHorizontalRegular
}[] = [
  { mode: 'force', labelKey: 'layout_force', Icon: OrganizationHorizontalRegular },
  { mode: 'hierarchy', labelKey: 'layout_hierarchy', Icon: TextBulletListTreeRegular },
  { mode: 'combo', labelKey: 'layout_combo', Icon: DataScatterRegular },
  { mode: 'radial', labelKey: 'layout_radial', Icon: CompassNorthwestRegular }
]

function parseLayoutMode(raw: string | null): AnkoleGraphLayoutMode {
  switch (raw) {
    case 'hierarchy':
    case 'combo':
    case 'radial':
      return raw
    default:
      return 'force'
  }
}

function BrainLayersCard({
  entityLayers,
  relationLayers,
  palette,
  hasHiddenLayers,
  onToggleEntityType,
  onToggleRelationKind,
  onReset,
  onClose
}: {
  entityLayers: readonly BrainEntityLayer[]
  relationLayers: readonly BrainRelationLayer[]
  palette: AnkoleCanvasThemePalette
  hasHiddenLayers: boolean
  onToggleEntityType: (entityType: string) => void
  onToggleRelationKind: (kind: BrainRelationKind) => void
  onReset: () => void
  onClose: () => void
}) {
  const { t } = useTranslation()

  return (
    <div className="ceramic w-56 rounded-control border border-border p-3 text-xs shadow-sm">
      <div className="mb-2.5 flex items-center justify-between gap-2">
        <span className="font-semibold text-fg-primary">{t('pod.meta.toggle_layers')}</span>
        <div className="flex items-center gap-1">
          {hasHiddenLayers && (
            <button
              type="button"
              onClick={onReset}
              className="rounded px-1.5 py-0.5 text-[11px] text-fg-secondary hover:bg-bg-secondary hover:text-fg-primary">
              {t('pod.meta.reset_layers')}
            </button>
          )}
          <button
            type="button"
            aria-label={t('common.close')}
            onClick={onClose}
            className="rounded p-0.5 text-fg-tertiary hover:bg-bg-secondary hover:text-fg-primary">
            <DismissRegular className="size-3.5" />
          </button>
        </div>
      </div>

      {entityLayers.length > 0 && (
        <div className="space-y-1">
          <div className="px-1 text-[11px] font-medium text-fg-tertiary uppercase">{t('pod.meta.layers_nodes')}</div>
          {entityLayers.map(layer => {
            const swatch = palette.ramps[layer.ramp].fill
            return (
              <button
                key={layer.type}
                type="button"
                aria-pressed={layer.visible}
                onClick={() => onToggleEntityType(layer.type)}
                className={`flex w-full items-center justify-between gap-2 rounded px-1.5 py-1 text-left transition-colors hover:bg-bg-secondary/70 ${
                  layer.visible ? 'text-fg-primary' : 'text-fg-tertiary opacity-55'
                }`}>
                <span className="flex min-w-0 items-center gap-2">
                  <span
                    className="size-2.5 shrink-0 rounded-full"
                    style={{ backgroundColor: swatch }}
                    aria-hidden="true"
                  />
                  <span className="truncate">{layer.type}</span>
                </span>
                <span className="shrink-0 font-mono text-[11px] text-fg-tertiary">{layer.count}</span>
              </button>
            )
          })}
        </div>
      )}

      {relationLayers.length > 0 && (
        <div className="mt-3 space-y-1 border-t border-border/70 pt-2.5">
          <div className="px-1 text-[11px] font-medium text-fg-tertiary uppercase">{t('pod.meta.layers_edges')}</div>
          {relationLayers.map(layer => {
            const swatch = palette.ramps[layer.ramp].fill
            const dashed = layer.kind === 'reference' || layer.kind === 'evidence'
            return (
              <button
                key={layer.kind}
                type="button"
                aria-pressed={layer.visible}
                onClick={() => onToggleRelationKind(layer.kind)}
                className={`flex w-full items-center justify-between gap-2 rounded px-1.5 py-1 text-left transition-colors hover:bg-bg-secondary/70 ${
                  layer.visible ? 'text-fg-primary' : 'text-fg-tertiary opacity-55'
                }`}>
                <span className="flex min-w-0 items-center gap-2">
                  <span
                    className="w-3.5 shrink-0 border-t-2"
                    style={{
                      borderColor: swatch,
                      borderStyle: dashed ? 'dashed' : 'solid'
                    }}
                    aria-hidden="true"
                  />
                  <span className="truncate">{t(`pod.meta.relation_${layer.kind}`)}</span>
                </span>
                <span className="shrink-0 font-mono text-[11px] text-fg-tertiary">{layer.count}</span>
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

function BrainInspectorCard({
  selection,
  palette,
  onSelectNode,
  onFocusNode,
  onCreateInCategory,
  onClose
}: {
  selection: BrainInspectorSelection
  palette: AnkoleCanvasThemePalette
  onSelectNode: (nodeId: string) => void
  onFocusNode: (nodeId: string) => void
  onCreateInCategory: (categoryName: string) => void
  onClose: () => void
}) {
  const { t } = useTranslation()
  const accent = palette.ramps[selection.ramp]

  if (selection.kind === 'hub') {
    return (
      <div className="ceramic w-72 space-y-3 rounded-control border border-border p-3.5 text-xs shadow-sm">
        <div className="flex items-start justify-between gap-2">
          <div className="min-w-0">
            <div className="flex items-center gap-2">
              <span
                className="size-2.5 shrink-0 rotate-45 rounded-[2px]"
                style={{ backgroundColor: accent.fill }}
                aria-hidden="true"
              />
              <span className="truncate text-sm font-semibold text-fg-primary">{selection.category.name}</span>
            </div>
            <div className="mt-0.5 font-mono text-[11px] text-fg-tertiary">
              {selection.category.entity_type} · {selection.category.primitive}
            </div>
          </div>
          <button
            type="button"
            aria-label={t('common.close')}
            onClick={onClose}
            className="rounded p-0.5 text-fg-tertiary hover:bg-bg-secondary hover:text-fg-primary">
            <DismissRegular className="size-4" />
          </button>
        </div>

        {selection.category.can_edit && (
          <Button
            size="sm"
            variant="outline"
            className="w-full justify-center gap-1.5"
            onClick={() => onCreateInCategory(selection.category.name)}>
            <AddRegular className="size-3.5" />
            {t('pod.meta.new_object')}
          </Button>
        )}

        <div className="space-y-1">
          <div className="text-[11px] font-medium text-fg-tertiary">
            {t('pod.meta.inspector_members')} ({selection.members.length})
          </div>
          <ul className="max-h-56 space-y-1 overflow-y-auto pr-0.5">
            {selection.members.map(member => (
              <li
                key={member.id}
                className="flex items-center justify-between gap-1 rounded px-1.5 py-1 hover:bg-bg-secondary/70">
                <Link
                  to={`/meta/brain/${member.id}`}
                  className="min-w-0 flex-1 truncate text-fg-primary hover:underline">
                  {member.title}
                </Link>
                <button
                  type="button"
                  aria-label={t('pod.meta.focus_node')}
                  onClick={() => {
                    onSelectNode(member.id)
                    onFocusNode(member.id)
                  }}
                  className="shrink-0 rounded p-0.5 text-fg-tertiary hover:bg-bg-secondary hover:text-fg-primary">
                  <TargetRegular className="size-3.5" />
                </button>
              </li>
            ))}
          </ul>
        </div>
      </div>
    )
  }

  const { object, category, ancestors, children, relations } = selection

  return (
    <div className="ceramic w-72 space-y-3 rounded-control border border-border p-3.5 text-xs shadow-sm">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <span
              className="size-2.5 shrink-0 rounded-full"
              style={{ backgroundColor: accent.fill }}
              aria-hidden="true"
            />
            <span className="truncate text-sm font-semibold text-fg-primary">{object.title}</span>
          </div>
          <div className="mt-1 flex flex-wrap items-center gap-1.5">
            <span
              className="rounded px-1.5 py-0.5 font-mono text-[11px]"
              style={{ backgroundColor: accent.subtle, color: accent.text }}>
              {object.subtype ? `${object.type} · ${object.subtype}` : object.type}
            </span>
            <span className="truncate font-mono text-[11px] text-fg-tertiary">{object.slug}</span>
          </div>
        </div>
        <button
          type="button"
          aria-label={t('common.close')}
          onClick={onClose}
          className="rounded p-0.5 text-fg-tertiary hover:bg-bg-secondary hover:text-fg-primary">
          <DismissRegular className="size-4" />
        </button>
      </div>

      <div className="flex items-center gap-1.5">
        <Link
          to={`/meta/brain/${object.id}`}
          className={cn(buttonVariants({ size: 'sm' }), 'flex-1 justify-center gap-1')}>
          <span>{t('pod.meta.open_object')}</span>
          <ArrowUpRightRegular className="size-3.5" />
        </Link>
        <Button
          size="sm"
          variant="outline"
          aria-label={t('pod.meta.focus_node')}
          onClick={() => onFocusNode(object.id)}>
          <TargetRegular className="size-3.5" />
        </Button>
      </div>

      {(category || ancestors.length > 0) && (
        <div className="space-y-1 border-t border-border/70 pt-2.5">
          <div className="text-[11px] font-medium text-fg-tertiary">{t('pod.meta.inspector_hierarchy')}</div>
          <div className="flex flex-wrap items-center gap-1 text-[11px] text-fg-secondary">
            {category && (
              <button
                type="button"
                onClick={() => onSelectNode(`hub:cat:${category.id}`)}
                className="rounded bg-bg-secondary px-1.5 py-0.5 font-medium text-fg-primary hover:underline">
                {category.name}
              </button>
            )}
            {ancestors.map(ancestor => (
              <span key={ancestor.id} className="inline-flex items-center gap-1">
                <span className="text-fg-tertiary">/</span>
                <button
                  type="button"
                  onClick={() => {
                    onSelectNode(ancestor.id)
                    onFocusNode(ancestor.id)
                  }}
                  className="max-w-36 truncate rounded bg-bg-secondary px-1.5 py-0.5 text-fg-primary hover:underline">
                  {ancestor.title}
                </button>
              </span>
            ))}
          </div>
        </div>
      )}

      {children.length > 0 && (
        <div className="space-y-1 border-t border-border/70 pt-2.5">
          <div className="text-[11px] font-medium text-fg-tertiary">
            {t('pod.meta.inspector_children')} ({children.length})
          </div>
          <ul className="max-h-28 space-y-1 overflow-y-auto pr-0.5">
            {children.map(child => (
              <li
                key={child.id}
                className="flex items-center justify-between gap-1 rounded px-1.5 py-0.5 hover:bg-bg-secondary/70">
                <Link
                  to={`/meta/brain/${child.id}`}
                  className="min-w-0 flex-1 truncate text-fg-primary hover:underline">
                  {child.title}
                </Link>
                <button
                  type="button"
                  aria-label={t('pod.meta.focus_node')}
                  onClick={() => {
                    onSelectNode(child.id)
                    onFocusNode(child.id)
                  }}
                  className="shrink-0 rounded p-0.5 text-fg-tertiary hover:text-fg-primary">
                  <TargetRegular className="size-3.5" />
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}

      {relations.length > 0 && (
        <div className="space-y-1 border-t border-border/70 pt-2.5">
          <div className="text-[11px] font-medium text-fg-tertiary">
            {t('pod.meta.inspector_relations')} ({relations.length})
          </div>
          <ul className="max-h-40 space-y-1 overflow-y-auto pr-0.5">
            {relations.map((rel, idx) => {
              const relAccent = palette.ramps[rel.ramp]
              return (
                <li
                  key={`${rel.direction}:${rel.linkType}:${rel.peer.id}:${idx}`}
                  className="flex items-center justify-between gap-1.5 rounded px-1.5 py-1 hover:bg-bg-secondary/70">
                  <span
                    className="shrink-0 rounded px-1.5 py-0.5 font-mono text-[10px]"
                    style={{ backgroundColor: relAccent.subtle, color: relAccent.text }}>
                    {rel.direction === 'outgoing' ? `→ ${rel.linkType}` : `← ${rel.linkType}`}
                  </span>
                  <Link
                    to={`/meta/brain/${rel.peer.id}`}
                    className="min-w-0 flex-1 truncate text-right text-fg-primary hover:underline">
                    {rel.peer.title}
                  </Link>
                </li>
              )
            })}
          </ul>
        </div>
      )}
    </div>
  )
}

export function MetaBrain() {
  const { t } = useTranslation()
  const graph = useQuery(metaBrainQuery())
  const [search, setSearch] = useState('')
  const [params, setParams] = useSearchParams()
  const category = params.get('category') ?? 'all'
  const layoutMode = parseLayoutMode(params.get('layout'))

  const [selectedNodeId, setSelectedNodeId] = useState<string | null>(null)
  const [hoveredDirectoryId, setHoveredDirectoryId] = useState<string | null>(null)
  const [layersOpen, setLayersOpen] = useState(true)
  const [includeCategoryHubs, setIncludeCategoryHubs] = useState(true)
  const [showEdgeLabels, setShowEdgeLabels] = useState(false)
  const [hiddenEntityTypes, setHiddenEntityTypes] = useState<Set<string>>(() => new Set())
  const [hiddenRelationKinds, setHiddenRelationKinds] = useState<Set<BrainRelationKind>>(() => new Set())

  const [creating, setCreating] = useState(false)
  const [createCategory, setCreateCategory] = useState<string | null>(null)
  const graphRef = useRef<AnkoleGraphHandle>(null)
  const palette = useCanvasThemePalette()
  const navigate = useNavigate()
  const client = useQueryClient()

  const data = graph.data
  const pages: BrainOntologyNode[] = usePagesMetadata(data?.nodes ?? [])

  const selected = data?.categories.find(item => item.name === category)
  const destination = data?.categories.find(item => item.name === (creating ? createCategory : category))
  const create = usePageCreation({
    parentID: destination?.id,
    onCreated: page => {
      setCreating(false)
      void client.invalidateQueries({ queryKey: metaKeys.brain() })
      void navigate({ to: `/meta/brain/${page.id}` })
    }
  })

  const projection = useMemo(
    () =>
      buildBrainOntologyGraph({
        categories: data?.categories ?? [],
        nodes: pages,
        links: data?.links ?? [],
        categoryFilter: category,
        search,
        layout: layoutMode,
        includeCategoryHubs,
        hiddenEntityTypes,
        hiddenRelationKinds
      }),
    [
      category,
      data?.categories,
      data?.links,
      hiddenEntityTypes,
      hiddenRelationKinds,
      includeCategoryHubs,
      layoutMode,
      pages,
      search
    ]
  )

  const selection = useMemo(() => projection.inspect(selectedNodeId), [projection, selectedNodeId])
  const hasHiddenLayers = hiddenEntityTypes.size > 0 || hiddenRelationKinds.size > 0

  const view = params.get('view')
  if (view === 'trash' || view === 'favorites') return <PageContentList scope={view} domain="brain" />

  return (
    <div className="mx-auto w-full max-w-7xl space-y-4 p-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-2xl font-semibold">{t('pod.meta.brain')}</h1>
        {data?.categories.some(item => item.can_edit) && (
          <Button
            disabled={create.isPending}
            onClick={() => {
              if (selected?.can_edit) void create.submit('knowledge')
              else {
                setCreateCategory(data.categories.find(item => item.can_edit)!.name)
                setCreating(true)
              }
            }}>
            {t('pod.meta.new_object')}
          </Button>
        )}
      </div>

      {creating && (
        <Dialog open onOpenChange={setCreating}>
          <DialogContent closeLabel={t('common.close')}>
            <DialogTitle>{t('pod.meta.new_object')}</DialogTitle>
            <label id="brain-create-category">{t('pod.meta.category')}</label>
            <Select value={createCategory ?? ''} onValueChange={value => setCreateCategory(String(value))}>
              <SelectTrigger aria-labelledby="brain-create-category">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {data?.categories
                  .filter(item => item.can_edit)
                  .map(item => (
                    <SelectItem key={item.id} value={item.name}>
                      {item.name}
                    </SelectItem>
                  ))}
              </SelectContent>
            </Select>
            <DialogFooter>
              <Button
                disabled={create.isPending || !destination?.can_edit}
                onClick={() => void create.submit('knowledge')}>
                {t('pod.meta.create')}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      )}

      <div className="flex flex-wrap items-end gap-3">
        <div className="min-w-52 flex-1">
          <label htmlFor="brain-search" className="mb-1 block text-sm">
            {t('pod.meta.find_object')}
          </label>
          <Input id="brain-search" value={search} onChange={event => setSearch(event.target.value)} />
        </div>

        <div className="w-48">
          <label id="brain-category" className="mb-1 block text-sm">
            {t('pod.meta.category')}
          </label>
          <Select
            value={category}
            onValueChange={value => {
              const next = new URLSearchParams(params)
              next.set('category', String(value))
              setParams(next)
            }}>
            <SelectTrigger aria-labelledby="brain-category" className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">{t('pod.meta.all_categories')}</SelectItem>
              {data?.categories.map(item => (
                <SelectItem key={item.id} value={item.name}>
                  {item.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        <ToggleGroup
          spacing={0}
          value={[layoutMode]}
          onValueChange={value => {
            const mode = value[0] as AnkoleGraphLayoutMode | undefined
            if (!mode || mode === layoutMode) return
            const next = new URLSearchParams(params)
            if (mode === 'force') next.delete('layout')
            else next.set('layout', mode)
            setParams(next)
          }}>
          {LAYOUT_OPTIONS.map(({ mode, labelKey, Icon }) => (
            <ToggleGroupItem key={mode} value={mode} aria-label={t(`pod.meta.${labelKey}`)}>
              <Icon className="size-3.5" />
              <span className="hidden sm:inline">{t(`pod.meta.${labelKey}`)}</span>
            </ToggleGroupItem>
          ))}
        </ToggleGroup>

        <div className="flex items-center gap-1.5">
          <Toggle
            variant="outline"
            aria-label={t('pod.meta.toggle_layers')}
            pressed={layersOpen}
            onPressedChange={setLayersOpen}>
            <StackRegular className="size-3.5" />
            <span className="hidden md:inline">{t('pod.meta.toggle_layers')}</span>
          </Toggle>
          {layoutMode !== 'combo' && (
            <Toggle
              variant="outline"
              aria-label={t('pod.meta.category_hubs')}
              pressed={includeCategoryHubs}
              onPressedChange={setIncludeCategoryHubs}>
              <TextBulletListTreeRegular className="size-3.5" />
              <span className="hidden lg:inline">{t('pod.meta.category_hubs')}</span>
            </Toggle>
          )}
          <Toggle
            variant="outline"
            aria-label={t('pod.meta.edge_labels')}
            pressed={showEdgeLabels}
            onPressedChange={setShowEdgeLabels}>
            <TagRegular className="size-3.5" />
            <span className="hidden lg:inline">{t('pod.meta.edge_labels')}</span>
          </Toggle>
        </div>

        <div className="flex items-center gap-1">
          <Button
            variant="outline"
            size="icon"
            onClick={() => graphRef.current?.zoomOut()}
            aria-label={t('pod.meta.zoom_out')}>
            <ZoomOutRegular className="size-4" />
          </Button>
          <Button
            variant="outline"
            size="icon"
            onClick={() => graphRef.current?.fitView()}
            aria-label={t('pod.meta.fit_view')}>
            <FullScreenMaximizeRegular className="size-4" />
          </Button>
          <Button
            variant="outline"
            size="icon"
            onClick={() => graphRef.current?.zoomIn()}
            aria-label={t('pod.meta.zoom_in')}>
            <ZoomInRegular className="size-4" />
          </Button>
        </div>
      </div>

      {graph.error && <ContentError error={graph.error} retry={() => void graph.refetch()} />}

      <AnkoleGraph
        ref={graphRef}
        ariaLabel={t('pod.meta.graph')}
        nodes={projection.nodes}
        edges={projection.edges}
        combos={projection.combos}
        layout={layoutMode}
        selectedNodeId={selectedNodeId}
        highlightedNodeId={hoveredDirectoryId}
        focusCenterNodeId={selectedNodeId}
        showEdgeLabels={showEdgeLabels}
        onSelectNode={setSelectedNodeId}
        onNavigateNode={node => {
          if (node.href) void navigate({ to: node.href })
        }}
        className="h-[64vh] min-h-[520px]"
        emptyState={
          !graph.isPending ? <p className="text-sm text-fg-secondary">{t('pod.meta.no_objects')}</p> : undefined
        }
        topLeftOverlay={
          layersOpen && (projection.entityLayers.length > 0 || projection.relationLayers.length > 0) ? (
            <BrainLayersCard
              entityLayers={projection.entityLayers}
              relationLayers={projection.relationLayers}
              palette={palette}
              hasHiddenLayers={hasHiddenLayers}
              onToggleEntityType={entityType => {
                setHiddenEntityTypes(prev => {
                  const next = new Set(prev)
                  if (next.has(entityType)) next.delete(entityType)
                  else next.add(entityType)
                  return next
                })
              }}
              onToggleRelationKind={kind => {
                setHiddenRelationKinds(prev => {
                  const next = new Set(prev)
                  if (next.has(kind)) next.delete(kind)
                  else next.add(kind)
                  return next
                })
              }}
              onReset={() => {
                setHiddenEntityTypes(new Set())
                setHiddenRelationKinds(new Set())
              }}
              onClose={() => setLayersOpen(false)}
            />
          ) : undefined
        }
        rightOverlay={
          selection ? (
            <BrainInspectorCard
              selection={selection}
              palette={palette}
              onSelectNode={setSelectedNodeId}
              onFocusNode={id => graphRef.current?.focusNode(id)}
              onCreateInCategory={catName => {
                setCreateCategory(catName)
                setCreating(true)
              }}
              onClose={() => setSelectedNodeId(null)}
            />
          ) : undefined
        }
        bottomOverlay={
          projection.visibleObjects.length > 0 ? (
            <div className="ceramic rounded-full border border-border px-3 py-1 text-xs text-fg-secondary shadow-xs">
              {t('pod.meta.graph_stats', {
                nodes: projection.visibleObjects.length,
                edges: projection.edges.length
              })}
            </div>
          ) : undefined
        }
      />

      {projection.visibleObjects.length > 0 && (
        <ul className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          {projection.visibleObjects.map(node => {
            const ramp = resolveBrainColorRamp(node.type)
            const dotColor = palette.ramps[ramp].fill
            const isSelected = selectedNodeId === node.id
            return (
              <li
                key={node.id}
                onMouseEnter={() => setHoveredDirectoryId(node.id)}
                onMouseLeave={() => setHoveredDirectoryId(prev => (prev === node.id ? null : prev))}
                className={`nav-row flex items-center justify-between gap-2 rounded-control px-2.5 py-1.5 ${
                  isSelected ? 'bg-bg-secondary ring-1 ring-border' : ''
                }`}>
                <Link to={`/meta/brain/${node.id}`} className="flex min-w-0 flex-1 items-center gap-2">
                  <span
                    className="size-2 shrink-0 rounded-full"
                    style={{ backgroundColor: dotColor }}
                    aria-hidden="true"
                  />
                  <span className="min-w-0 truncate">{node.title}</span>
                </Link>
                <div className="flex shrink-0 items-center gap-1.5">
                  <span className="text-xs text-fg-tertiary">{node.type}</span>
                  <button
                    type="button"
                    aria-label={t('pod.meta.focus_node')}
                    onClick={() => {
                      setSelectedNodeId(node.id)
                      graphRef.current?.focusNode(node.id)
                    }}
                    className="rounded p-1 text-fg-tertiary hover:bg-bg-secondary hover:text-fg-primary">
                    <TargetRegular className="size-3.5" />
                  </button>
                </div>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}

export function MetaBrainObject() {
  return <PageRoute />
}
