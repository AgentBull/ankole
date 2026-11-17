import { parseEmbedProps, type EmbedAttributes } from '@ankole/block-editor/editor'
import type { BaseTable, BaseView } from '@ankole/applet-sdk/types'
import {
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  Label,
  Textarea
} from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import {
  CheckmarkRegular,
  ChevronDownRegular,
  CodeRegular,
  DataHistogramRegular,
  DismissRegular,
  MentionRegular,
  OpenRegular,
  WindowRegular
} from '@ankole/uikit/icons'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useEffect, useId, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ErrorBoundary } from '../common/error-boundary'
import { baseSchemaQuery, baseTablesQuery } from './base-api'
import { pageQuery } from './content-api'
import { ContentLoading, ContentSkeleton, InlineLoading } from './content-primitives'
import { PageContent } from './page-content'
import { PageIcon } from './page-icon'
import { DocumentDraftModel } from './state/document-draft'
import { looksLikeChartEmbedView, parseEmbedView } from './state/view-config'
import { usePageMetadata } from './use-page-metadata'

const BasePage = lazy(() => import('./base-page').then(module => ({ default: module.BasePage })))
const AppletPage = lazy(() => import('./applet-page').then(module => ({ default: module.AppletPage })))
const PagePicker = lazy(() => import('./page-picker').then(module => ({ default: module.PagePicker })))

export function ChartEmbedPickerDialog({
  pageID,
  creatingBase,
  onClose,
  onFocusEditor,
  onCreateNewBase,
  onInsert
}: {
  pageID: string
  creatingBase: boolean
  onClose(): void
  onFocusEditor(): void
  onCreateNewBase(): void
  onInsert(attrs: EmbedAttributes): void
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const requestIdRef = useRef(0)
  useEffect(
    () => () => {
      requestIdRef.current++
    },
    []
  )
  const [inspecting, setInspecting] = useState(false)
  const [choiceState, setChoiceState] = useState<{
    baseId: string
    tables: { table: BaseTable; chartViews: BaseView[] }[]
  } | null>(null)

  const handleBaseSelected = async (baseId: string) => {
    const requestId = ++requestIdRef.current
    setInspecting(true)
    try {
      const { tables } = await client.fetchQuery(baseTablesQuery(baseId))
      if (requestId !== requestIdRef.current) return
      const schemas = await Promise.all(
        tables.map(async table => {
          const schema = await client.fetchQuery(baseSchemaQuery(table.id))
          return {
            table,
            chartViews: schema.views.filter(v => v.type === 'chart')
          }
        })
      )
      if (requestId !== requestIdRef.current) return
      const totalSavedCharts = schemas.reduce((sum, entry) => sum + entry.chartViews.length, 0)
      if (tables.length <= 1 && totalSavedCharts === 0) {
        onInsert({
          ref: baseId,
          ...(tables[0] ? { table: tables[0].id } : {}),
          view: JSON.stringify({ type: 'chart' })
        })
        return
      }
      setChoiceState({ baseId, tables: schemas })
    } catch {
      if (requestId !== requestIdRef.current) return
      onInsert({ ref: baseId, view: JSON.stringify({ type: 'chart' }) })
    } finally {
      if (requestId === requestIdRef.current) setInspecting(false)
    }
  }

  const savedCharts = choiceState?.tables.flatMap(entry => entry.chartViews.map(view => ({ table: entry.table, view })))

  return (
    <Dialog
      open
      onOpenChange={next => {
        if (!next) {
          requestIdRef.current++
          onClose()
        }
      }}>
      <DialogContent
        className="pod-dialog pod-picker-dialog"
        closeLabel={t('common.close')}
        finalFocus={() => {
          onFocusEditor()
          return false
        }}>
        <DialogTitle>{t('pod.content.embed_base_chart', { defaultValue: 'Insert Base chart' })}</DialogTitle>
        <div className="pod-dialog-body grid gap-3">
          {choiceState ? (
            <div className="space-y-4 text-sm" data-slot="chart-picker-options">
              {savedCharts && savedCharts.length > 0 && (
                <div className="space-y-1.5">
                  <p className="text-xs font-medium text-fg-secondary">
                    {t('pod.content.link_existing_chart_view', { defaultValue: 'Link existing chart view' })}
                  </p>
                  <div className="grid gap-1">
                    {savedCharts.map(({ table, view }) => (
                      <Button
                        key={view.id}
                        variant="outline"
                        size="sm"
                        className="justify-between"
                        onClick={() =>
                          onInsert({
                            ref: choiceState.baseId,
                            table: table.id,
                            view: view.id
                          })
                        }>
                        <span className="inline-flex items-center gap-1.5 truncate">
                          <DataHistogramRegular aria-hidden="true" className="size-4 shrink-0" />
                          <span className="truncate">{view.name}</span>
                        </span>
                        {choiceState.tables.length > 1 && (
                          <span className="text-xs text-fg-tertiary">{table.name}</span>
                        )}
                      </Button>
                    ))}
                  </div>
                </div>
              )}

              <div className="space-y-1.5">
                <p className="text-xs font-medium text-fg-secondary">
                  {t('pod.content.new_inline_chart_for_table', { defaultValue: 'New chart in document' })}
                </p>
                <div className="grid gap-1">
                  {choiceState.tables.map(({ table }) => (
                    <Button
                      key={table.id}
                      variant="ghost"
                      size="sm"
                      className="justify-start border border-border-subtle/60"
                      onClick={() =>
                        onInsert({
                          ref: choiceState.baseId,
                          table: table.id,
                          view: JSON.stringify({ type: 'chart' })
                        })
                      }>
                      <DataHistogramRegular aria-hidden="true" className="size-4 shrink-0 text-fg-secondary" />
                      <span className="truncate">{table.name}</span>
                    </Button>
                  ))}
                </div>
              </div>
            </div>
          ) : (
            <ErrorBoundary variant="panel" resetKeys={[pageID]}>
              <Suspense fallback={<InlineLoading />}>
                <PagePicker
                  embeddable
                  disabled={inspecting}
                  canSelect={page => page.type === 'base'}
                  label={t('pod.content.choose_base_for_chart', { defaultValue: 'Choose a Base' })}
                  onSelect={id => {
                    void handleBaseSelected(id)
                  }}
                />
              </Suspense>
            </ErrorBoundary>
          )}
        </div>
        <DialogFooter>
          {choiceState ? (
            <Button variant="ghost" size="sm" onClick={() => setChoiceState(null)}>
              {t('pod.content.choose_another_base', { defaultValue: 'Choose another Base' })}
            </Button>
          ) : (
            <Button variant="outline" size="sm" disabled={creatingBase || inspecting} onClick={onCreateNewBase}>
              {t('pod.content.create_new_base_chart', { defaultValue: 'Create new Base & chart' })}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export function PageEmbed({
  attributes,
  canEdit,
  trashed,
  model,
  remove,
  collapseToMention,
  configure,
  configureProps,
  bindSavedView,
  openPage
}: {
  attributes: EmbedAttributes
  canEdit: boolean
  trashed: boolean
  model: InstanceType<typeof DocumentDraftModel>
  remove(): void
  collapseToMention?(): void
  configure(config: Record<string, unknown>, table?: string): void
  configureProps?(props: string): void
  bindSavedView?(viewID: string, table?: string): void
  openPage(id: string): void
}) {
  useSignals()
  const { t } = useTranslation()
  const editable = canEdit && !model.conflict.value
  const query = useQuery({ ...pageQuery(attributes.ref ?? ''), enabled: !!attributes.ref })
  const page = usePageMetadata(query.data?.page)
  const containerRef = useRef<HTMLDivElement | null>(null)
  const view = parseEmbedView(attributes.view)
  const embedProps = useMemo(() => parseEmbedProps(attributes.props), [attributes.props])
  const [propsOpen, setPropsOpen] = useState(false)
  const isChartIntent =
    (view.kind === 'inline' && view.config.type === 'chart') || looksLikeChartEmbedView(attributes.view)
  const [chartVisible, setChartVisible] = useState<boolean>(
    () => !isChartIntent || typeof IntersectionObserver === 'undefined'
  )

  useEffect(() => {
    if (chartVisible || !isChartIntent) {
      setChartVisible(true)
      return
    }
    const el = containerRef.current
    if (!el || typeof IntersectionObserver === 'undefined') {
      setChartVisible(true)
      return
    }
    const observer = new IntersectionObserver(
      entries => {
        if (entries.some(entry => entry.isIntersecting)) {
          setChartVisible(true)
          observer.disconnect()
        }
      },
      { rootMargin: '300px' }
    )
    observer.observe(el)
    return () => observer.disconnect()
  }, [chartVisible, isChartIntent])

  const cannotDisplay = (
    <div className="flex items-center justify-between gap-2 p-4 text-sm text-fg-tertiary">
      <span>{t('pod.content.cannot_display')}</span>
      {editable && !trashed && (
        <Button
          size="icon-xs"
          variant="ghost"
          aria-label={t('pod.content.remove')}
          title={t('pod.content.remove')}
          onClick={remove}>
          <DismissRegular aria-hidden className="size-4" />
        </Button>
      )}
    </div>
  )
  if (!attributes.ref) {
    return cannotDisplay
  }
  if (query.error) {
    return cannotDisplay
  }
  if (!query.data || !page) {
    return <ContentLoading />
  }
  if (page.type === 'doc') {
    return cannotDisplay
  }
  const embedTrashed = trashed || Boolean(query.data.page.deleted_at)
  const embeddedDetail = embedTrashed ? { ...query.data, actions: ['node_view' as const] } : query.data
  const canConfigureEmbed = editable && !embedTrashed
  return (
    <div
      ref={containerRef}
      className="pod-inline-page group/inline-page my-4 min-w-0"
      data-page-type={page.type}
      data-chart-embed={isChartIntent || undefined}>
      <div className="mb-1.5 flex min-w-0 items-center justify-between gap-2">
        <Button
          variant="ghost"
          className="-ml-1 h-7.5 min-w-0 max-w-full justify-start px-1 py-0.5 text-base font-semibold"
          onClick={() => openPage(query.data!.page.id)}>
          <PageIcon page={page} />
          <span className="truncate">{page.title || t('pod.content.untitled')}</span>
          <OpenRegular aria-hidden className="shrink-0" />
        </Button>
        {canConfigureEmbed && (collapseToMention || configureProps) && (
          <DropdownMenu modal={false}>
            <DropdownMenuTrigger
              render={
                <Button
                  variant="ghost"
                  size="xs"
                  className="shrink-0 gap-1 text-fg-secondary opacity-0 transition-opacity duration-120 group-focus-within/inline-page:opacity-100 group-hover/inline-page:opacity-100 data-popup-open:opacity-100 [@media(hover:none)]:opacity-100"
                  aria-label={t('pod.editor.resource_view')}
                />
              }>
              <WindowRegular aria-hidden />
              <span>{t('pod.editor.mention_view_embed')}</span>
              <ChevronDownRegular aria-hidden />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" aria-label={t('pod.editor.resource_view')}>
              {collapseToMention && (
                <DropdownMenuItem onClick={collapseToMention}>
                  <MentionRegular aria-hidden />
                  <span>{t('pod.editor.mention_view_inline')}</span>
                </DropdownMenuItem>
              )}
              <DropdownMenuItem data-active="true">
                <WindowRegular aria-hidden />
                <span>{t('pod.editor.mention_view_embed')}</span>
                <CheckmarkRegular aria-hidden className="ml-auto text-fg-primary" />
              </DropdownMenuItem>
              {page.type === 'applet' && configureProps && (
                <DropdownMenuItem onClick={() => setPropsOpen(true)}>
                  <CodeRegular aria-hidden />
                  <span>{t('pod.content.embed_props')}</span>
                </DropdownMenuItem>
              )}
            </DropdownMenuContent>
          </DropdownMenu>
        )}
      </div>
      {page.type === 'base' ? (
        !chartVisible ? (
          <ContentSkeleton variant="block" className="h-[280px]" />
        ) : (
          <Suspense fallback={<ContentSkeleton variant="block" className="h-[280px]" immediate />}>
            {view.kind === 'invalid' ? (
              <div className="space-y-2 p-4" role="alert">
                <p>{t('pod.content.cannot_display')}</p>
                {canConfigureEmbed && (
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => configure({ type: looksLikeChartEmbedView(attributes.view) ? 'chart' : 'grid' })}>
                    {t('pod.content.discard_view_changes')}
                  </Button>
                )}
              </div>
            ) : (
              <BasePage
                detail={embeddedDetail}
                tableID={attributes.table}
                viewID={view.kind === 'saved' ? view.id : undefined}
                inlineConfig={view.kind === 'inline' ? view.config : undefined}
                configureInline={canConfigureEmbed ? configure : undefined}
                bindSavedView={canConfigureEmbed ? bindSavedView : undefined}
                embedded
              />
            )}
          </Suspense>
        )
      ) : page.type === 'applet' && embedTrashed ? (
        <div className="p-4 text-sm text-fg-secondary" role="status">
          {t('pod.content.applet_inactive_in_trash')}
        </div>
      ) : page.type === 'applet' ? (
        <Suspense fallback={<ContentLoading label={t('pod.content.loading_applet')} />}>
          <AppletPage detail={embeddedDetail} embedProps={embedProps} embedded />
        </Suspense>
      ) : (
        <PageContent detail={embeddedDetail} embedded />
      )}
      {propsOpen && canConfigureEmbed && configureProps && (
        <EmbedPropsDialog
          source={attributes.props}
          onClose={() => setPropsOpen(false)}
          onSave={props => {
            configureProps(props)
            setPropsOpen(false)
          }}
        />
      )}
    </div>
  )
}

function EmbedPropsDialog({
  source,
  onSave,
  onClose
}: {
  source?: string
  onSave(props: string): void
  onClose(): void
}) {
  const { t } = useTranslation()
  const id = useId()
  const [draft, setDraft] = useState(() => JSON.stringify(parseEmbedProps(source), null, 2))
  let value: string | undefined
  let validationError: string | undefined
  try {
    value = JSON.stringify(parseEmbedProps(draft))
  } catch (error) {
    value = undefined
    validationError = error instanceof Error ? error.message : String(error)
  }
  return (
    <Dialog open onOpenChange={open => !open && onClose()}>
      <DialogContent className="pod-dialog max-w-lg" closeLabel={t('common.close')}>
        <DialogTitle>{t('pod.content.embed_props')}</DialogTitle>
        <div className="pod-dialog-body space-y-2">
          <Label htmlFor={id}>{t('pod.content.embed_props_json')}</Label>
          <Textarea
            id={id}
            className="min-h-48 font-mono"
            value={draft}
            onChange={event => setDraft(event.target.value)}
            aria-invalid={value === undefined}
            aria-describedby={validationError ? `${id}-error ${id}-hint` : `${id}-hint`}
          />
          {validationError && (
            <p id={`${id}-error`} role="alert" className="text-xs text-destructive">
              {validationError}
            </p>
          )}
          <p id={`${id}-hint`} className="text-xs text-fg-secondary">
            {t('pod.content.embed_props_hint')}
          </p>
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>
            {t('common.cancel')}
          </Button>
          <Button disabled={value === undefined} onClick={() => value !== undefined && onSave(value)}>
            {t('common.save')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
