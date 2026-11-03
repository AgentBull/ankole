import {
  Button,
  Dialog,
  DialogContent,
  DialogTitle,
  DialogFooter,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@ankole/uikit'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useNavigate } from '@tanstack/react-router'
import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ContentError } from './content-primitives'
import { usePageCreation } from './page-create-menu'
import { PageContentList } from './content-list'
import { brainGraphLayout } from './state/brain-graph'
import { PageRoute } from './page-workspace'
import { metaBrainQuery, metaKeys } from './meta-api'
import { useSearchParams } from '../common/router'
import { usePagesMetadata } from './use-page-metadata'

export function MetaBrain() {
  const { t } = useTranslation()
  const graph = useQuery(metaBrainQuery())
  const [search, setSearch] = useState('')
  const [params, setParams] = useSearchParams()
  const category = params.get('category') ?? 'all'
  const [zoom, setZoom] = useState(1)
  const [focused, setFocused] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [createCategory, setCreateCategory] = useState<string | null>(null)
  const pan = useRef<{ x: number; y: number; left: number; top: number } | null>(null)
  const navigate = useNavigate()
  const client = useQueryClient()
  const data = graph.data
  const pages = usePagesMetadata(data?.nodes ?? [])
  const nodes = pages.filter(
    node =>
      (category === 'all' || node.slug.startsWith(`${category}/`)) &&
      `${node.title} ${node.slug}`.toLocaleLowerCase().includes(search.toLocaleLowerCase())
  )
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
  const layout = brainGraphLayout(nodes, data?.links ?? [])
  const { positions } = layout
  const view = params.get('view')
  if (view === 'trash' || view === 'favorites') return <PageContentList scope={view} domain="brain" />
  return (
    <div className="mx-auto w-full max-w-6xl space-y-5 p-6">
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
      <div className="flex flex-wrap items-end gap-4">
        <div className="min-w-48 flex-1">
          <label htmlFor="brain-search" className="mb-1 block text-sm">
            {t('pod.meta.find_object')}
          </label>
          <Input id="brain-search" value={search} onChange={event => setSearch(event.target.value)} />
        </div>
        <div className="w-52">
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
            <SelectTrigger aria-labelledby="brain-category">
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
        <Button
          variant="outline"
          onClick={() => setZoom(Math.max(0.5, zoom - 0.25))}
          aria-label={t('pod.meta.zoom_out')}>
          −
        </Button>
        <Button variant="outline" onClick={() => setZoom(Math.min(3, zoom + 0.25))} aria-label={t('pod.meta.zoom_in')}>
          +
        </Button>
      </div>
      {graph.error && <ContentError error={graph.error} retry={() => void graph.refetch()} />}
      <figure
        className="max-h-[65vh] overflow-auto rounded-lg border border-border bg-bg-secondary/30"
        onPointerDown={event => {
          if (event.pointerType !== 'mouse' || event.button !== 0 || (event.target as Element).closest('a')) return
          const element = event.currentTarget
          pan.current = { x: event.clientX, y: event.clientY, left: element.scrollLeft, top: element.scrollTop }
          element.setPointerCapture(event.pointerId)
        }}
        onPointerMove={event => {
          if (!pan.current) return
          event.currentTarget.scrollLeft = pan.current.left + pan.current.x - event.clientX
          event.currentTarget.scrollTop = pan.current.top + pan.current.y - event.clientY
        }}
        onPointerUp={() => {
          pan.current = null
        }}
        onPointerCancel={() => {
          pan.current = null
        }}>
        <svg
          viewBox={`0 0 ${layout.width} ${layout.height}`}
          style={{ width: layout.width * zoom, height: layout.height * zoom }}
          className="max-w-none"
          role="group"
          aria-label={t('pod.meta.graph')}>
          <defs>
            <marker
              id="brain-arrow"
              viewBox="0 0 10 10"
              refX="12"
              refY="5"
              markerWidth="5"
              markerHeight="5"
              orient="auto-start-reverse">
              <path d="M 0 0 L 10 5 L 0 10 z" fill="currentColor" />
            </marker>
          </defs>
          {data?.links.map((edge, index) => {
            const start = positions.get(edge.from_page_id),
              end = positions.get(edge.to_page_id)
            return (
              start &&
              end && (
                <g
                  key={index}
                  className={
                    focused && [edge.from_page_id, edge.to_page_id].includes(focused)
                      ? 'text-fg-primary'
                      : 'text-fg-tertiary'
                  }>
                  <line
                    x1={start.x}
                    y1={start.y}
                    x2={end.x}
                    y2={end.y}
                    stroke="currentColor"
                    strokeOpacity={focused && [edge.from_page_id, edge.to_page_id].includes(focused) ? 1 : 0.25}
                    strokeWidth={focused && [edge.from_page_id, edge.to_page_id].includes(focused) ? 2 : 1}
                    markerEnd="url(#brain-arrow)"
                  />
                  <title>{edge.link_type}</title>
                </g>
              )
            )
          })}
          {nodes.map(node => {
            const point = positions.get(node.id)!
            return (
              <a
                key={node.id}
                href={`/meta/brain/${node.id}`}
                aria-label={node.title}
                onClick={event => {
                  if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
                  event.preventDefault()
                  void navigate({ to: `/meta/brain/${node.id}` })
                }}
                onMouseEnter={() => setFocused(node.id)}
                onMouseLeave={() => setFocused(null)}
                onFocus={() => setFocused(node.id)}
                onBlur={() => setFocused(null)}
                style={{
                  opacity: !focused || focused === node.id || layout.neighbors.get(focused)?.has(node.id) ? 1 : 0.35
                }}
                className="text-fg-primary">
                <rect
                  x={point.x - 100}
                  y={point.y - 16}
                  width="200"
                  height="48"
                  rx="8"
                  fill="var(--color-background)"
                  stroke="currentColor"
                  strokeOpacity=".2"
                />
                <circle cx={point.x} cy={point.y} r="7" fill="currentColor" />
                <foreignObject x={point.x - 94} y={point.y + 8} width="188" height="20">
                  <div className="truncate text-center text-xs leading-5">{node.title}</div>
                </foreignObject>
                <title>
                  {node.title} · {node.type}
                </title>
              </a>
            )
          })}
        </svg>
        <figcaption className="px-4 pb-3 text-sm text-fg-secondary">
          {t('pod.meta.graph_hint', { count: nodes.length })}
        </figcaption>
      </figure>
      {nodes.length === 0 && !graph.isPending && (
        <p className="text-sm text-fg-secondary">{t('pod.meta.no_objects')}</p>
      )}
      <ul className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        {nodes.map(node => (
          <li key={node.id}>
            <Link
              to={`/meta/brain/${node.id}`}
              className="nav-row flex items-center justify-between gap-3 rounded-control px-2 py-1">
              <span className="min-w-0 truncate">{node.title}</span>
              <span className="shrink-0 text-xs text-fg-tertiary">{node.type}</span>
            </Link>
          </li>
        ))}
      </ul>
    </div>
  )
}
export function MetaBrainObject() {
  return <PageRoute />
}
