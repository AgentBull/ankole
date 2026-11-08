import { fieldIcons } from './base-field-types'
import { createAppletRoutes } from './applet-routes'
import { createAppletRuns } from './applet-runs'
import { pageCreated } from './state/navigation-cache'
import { t } from 'i18next'
import { useTranslation } from 'react-i18next'
import { AppletRuntimeProvider, useAggregate, useRecords, useRecordWrites } from '@ankole/applet-sdk'
import type {
  AppletRuntime,
  BaseField,
  BaseTable,
  BaseView,
  Filter,
  RecordQuery,
  ViewType
} from '@ankole/applet-sdk/types'
import {
  Button,
  Checkbox,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  Input,
  Popover,
  PopoverTrigger,
  PopoverContent,
  PopoverTitle,
  toast,
  useTheme
} from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { TableWorkspaceModel } from './state/table-workspace'
import { isUnconfiguredChartSpec, parseViewConfig, type ViewConfig, type ConfiguredView } from './state/view-config'
import { deriveDefaultChartSpec, serializeResolvedToViewConfig } from './state/chart-view'
import { useEffect, useId, useMemo, useRef, useState } from 'react'
import {
  RiAddLine,
  RiBarChartBoxLine,
  RiCloseLine,
  RiEqualizerLine,
  RiFileCopyLine,
  RiGalleryLine,
  RiLayoutColumnLine,
  RiTableLine
} from '@remixicon/react'
import { contentKeys, limitPageTitle, podRequest, type PageDetail } from './content-api'
import { ErrorBoundary } from '../common/error-boundary'
import { useContent } from './content-context'
import { usePageHref } from './use-page-metadata'
import { ContentError, ContentSkeleton } from './content-primitives'
import { baseHTTP, baseTablesQuery, baseSchemaQuery } from './base-api'
import { BaseViewContent, RecordForm, type ViewProps } from './base-views'
import { QueryControls } from './base-query-controls'
import { FieldEditorButton } from './base-fields'
import { podBaseCopy } from './api/generated/sdk.gen'
import { pageSearchQuery, pageQuery, type Page } from './content-api'
import { BaseSummary } from './base-summary'
import { PagePicker } from './page-picker'
import { requestErrorMessage } from '../common/request-errors'
import { contentError } from './content-errors'
import './base.css'

export const viewLabels: Record<ViewType, string> = {
  get grid() {
    return t('pod.content.grid')
  },
  get kanban() {
    return t('pod.content.board')
  },
  get gallery() {
    return t('pod.content.gallery')
  },
  get chart() {
    return t('pod.content.chart', { defaultValue: 'Chart' })
  }
}

const viewIcons: Record<ViewType, typeof RiTableLine> = {
  grid: RiTableLine,
  kanban: RiLayoutColumnLine,
  gallery: RiGalleryLine,
  chart: RiBarChartBoxLine
}

type EmbedBridge = {
  inlineConfig?: ViewConfig
  configureInline?: (config: ViewConfig, table?: string) => void
  bindSavedView?: (viewID: string, table?: string) => void
}

export function BasePage({
  detail,
  tableID,
  viewID,
  inlineConfig,
  configureInline,
  bindSavedView,
  embedded = false
}: {
  detail: PageDetail
  tableID?: string
  viewID?: string
  inlineConfig?: ViewConfig
  configureInline?: (config: ViewConfig, table?: string) => void
  bindSavedView?: (viewID: string, table?: string) => void
  embedded?: boolean
}) {
  const { base, realtime, readDenial } = useContent()
  const { resolvedTheme } = useTheme()
  const theme = resolvedTheme === 'dark' ? 'dark' : 'light'
  const client = useQueryClient()
  const runtime = useMemo<AppletRuntime>(
    () => ({
      pageID: detail.page.id,
      instanceID: `base-${detail.page.id}`,
      revision: detail.page.revision,
      actions: detail.actions,
      routes: createAppletRoutes(detail.page.id, detail.page.revision, () => {
        void client.invalidateQueries({ queryKey: contentKeys.page(detail.page.id) })
      }),
      queryClient: client,
      readDenial,
      base,
      runs: createAppletRuns(client, realtime, detail.page.id),
      pod: { request: podRequest },
      channel: name => realtime.channel(detail.page.id, name),
      principal: realtime.principal,
      theme
    }),
    [detail.page.id, detail.page.revision, detail.actions, client, readDenial, base, realtime, theme]
  )
  const isEmbed = embedded || Boolean(configureInline || inlineConfig || bindSavedView)
  return (
    <AppletRuntimeProvider runtime={runtime}>
      <BaseWorkspace
        detail={detail}
        initialTable={tableID}
        initialView={viewID}
        embed={isEmbed ? { inlineConfig, configureInline, bindSavedView } : undefined}
      />
    </AppletRuntimeProvider>
  )
}

function nextTableName(tables: BaseTable[]): string {
  const existing = new Set(tables.map(table => table.name.trim()))
  const prefix = t('pod.content.table')
  for (let index = 1; index <= tables.length + 1; index++) {
    const candidate = `${prefix} ${index}`
    if (!existing.has(candidate)) return candidate
  }
  return `${prefix} ${tables.length + 1}`
}

export function nextViewName(views: readonly Pick<BaseView, 'name'>[], baseLabel: string): string {
  const trimmedBase = baseLabel.trim() || 'View'
  const existing = new Set(views.map(v => v.name.trim()))
  if (!existing.has(trimmedBase)) return trimmedBase
  for (let index = 2; index <= views.length + 2; index++) {
    const candidate = `${trimmedBase} ${index}`
    if (!existing.has(candidate)) return candidate
  }
  return `${trimmedBase} ${views.length + 2}`
}

export function sanitizeViewConfig(config: ViewConfig, fields: BaseField[], viewType?: ViewType): ViewConfig {
  if (viewType === 'chart' || config.type === 'chart' || Boolean(config.chart) || Boolean(config.chart_type)) {
    // Preserve chart field references intact so deleted fields trigger in-place repair instead of silent erasure.
    return { ...config }
  }
  const known = new Set(fields.map(field => field.id))
  const primaryID = fields.find(field => field.is_primary)?.id
  const next: ViewConfig = { ...config }
  if (next.visible_fields) {
    const filtered = next.visible_fields.filter(id => known.has(id))
    next.visible_fields = primaryID && !filtered.includes(primaryID) ? [primaryID, ...filtered] : filtered
  }
  if (!next.group_field_id || !known.has(next.group_field_id)) delete next.group_field_id
  if (!next.cover_field_id || !known.has(next.cover_field_id)) delete next.cover_field_id
  return next
}

function BaseWorkspace({
  detail,
  initialTable,
  initialView,
  embed
}: {
  detail: PageDetail
  initialTable?: string
  initialView?: string
  embed?: EmbedBridge
}) {
  const { t } = useTranslation()
  const tables = useQuery(baseTablesQuery(detail.page.id))
  const [selected, setSelected] = useState(initialTable ?? '')
  const [renaming, setRenaming] = useState<string>()
  const [deleting, setDeleting] = useState(false)
  const tableSaving = useRef(false)
  const client = useQueryClient()
  const tablesQueryKey = [...contentKeys.page(detail.page.id), 'tables']
  const create = useMutation({
    mutationFn: () => baseHTTP.createTable(detail.page.id, nextTableName(tables.data?.tables ?? [])),
    onSuccess: async ({ table }) => {
      await client.invalidateQueries({ queryKey: tablesQueryKey })
      setSelected(table.id)
      setRenaming(table.id)
    },
    onSettled: () => {
      tableSaving.current = false
    }
  })
  const explicitMissingTable =
    Boolean(initialTable) &&
    Boolean(tables.data) &&
    selected === initialTable &&
    !tables.data!.tables.some(table => table.id === selected)
  const tableID = explicitMissingTable
    ? undefined
    : tables.data?.tables.some(table => table.id === selected)
      ? selected
      : tables.data?.tables[0]?.id
  const activeEmbedSchema = useQuery({
    ...baseSchemaQuery(tableID ?? ''),
    enabled: Boolean(embed && tableID)
  })
  const resolvedEmbedView = embed?.inlineConfig
    ? undefined
    : initialView
      ? activeEmbedSchema.data?.views.find(item => item.id === initialView)
      : activeEmbedSchema.data?.views[0]
  const quietSingleChartEmbed = Boolean(
    embed && (embed.inlineConfig?.type === 'chart' || resolvedEmbedView?.type === 'chart')
  )
  const remove = useMutation({
    mutationFn: () => baseHTTP.removeTable(tableID!),
    onSuccess: async () => {
      setDeleting(false)
      setSelected('')
      await Promise.all([
        client.invalidateQueries({ queryKey: tablesQueryKey }),
        client.invalidateQueries({ queryKey: [...contentKeys.all, 'table'] }),
        client.invalidateQueries({ queryKey: [...contentKeys.all, 'reference-labels'] })
      ])
    }
  })
  const hasTableActions = detail.actions.includes('node_edit') || detail.actions.includes('node_manage')
  return (
    <section className="pod-base min-w-0" data-inline={!!embed} data-quiet-chart={quietSingleChartEmbed || undefined}>
      {!quietSingleChartEmbed && !explicitMissingTable && (
        <div className="pod-base-sources" aria-label={t('pod.content.table')}>
          {tables.data?.tables.map(table =>
            renaming === table.id ? (
              <DefinitionName
                key={table.id}
                name={table.name}
                label={t('pod.content.table_name')}
                invalidateKey={tablesQueryKey}
                save={name => baseHTTP.renameTable(table.id, name)}
                close={() => setRenaming(undefined)}
              />
            ) : (
              <div key={table.id} className="inline-flex shrink-0 items-center gap-0.5">
                <Button
                  size="sm"
                  variant="ghost"
                  className={table.id === tableID ? 'font-semibold' : undefined}
                  aria-pressed={table.id === tableID}
                  onDoubleClick={() => detail.actions.includes('node_edit') && setRenaming(table.id)}
                  onClick={() => {
                    setSelected(table.id)
                    if (embed?.inlineConfig && embed.configureInline) {
                      embed.configureInline({ type: embed.inlineConfig.type ?? 'grid' }, table.id)
                    } else if (embed?.bindSavedView) {
                      embed.bindSavedView('', table.id)
                    }
                  }}>
                  {table.name}
                </Button>
                {hasTableActions && table.id === tableID && (
                  <DropdownMenu>
                    <DropdownMenuTrigger
                      render={<Button size="icon-sm" variant="ghost" aria-label={t('pod.content.table_actions')} />}>
                      ⋯
                    </DropdownMenuTrigger>
                    <DropdownMenuContent>
                      {detail.actions.includes('node_edit') && (
                        <DropdownMenuItem onClick={() => setRenaming(table.id)}>
                          {t('pod.sidebar.rename')}
                        </DropdownMenuItem>
                      )}
                      {detail.actions.includes('node_manage') && (
                        <DropdownMenuItem
                          variant="destructive"
                          onClick={() => {
                            remove.reset()
                            setDeleting(true)
                          }}>
                          {t('pod.content.delete_table')}
                        </DropdownMenuItem>
                      )}
                    </DropdownMenuContent>
                  </DropdownMenu>
                )}
              </div>
            )
          )}
          {detail.actions.includes('node_edit') && (
            <Button
              size="sm"
              variant="ghost"
              disabled={create.isPending}
              onClick={() => {
                if (!tableSaving.current) {
                  tableSaving.current = true
                  create.mutate()
                }
              }}>
              {t('pod.content.table_2')}
            </Button>
          )}
        </div>
      )}
      <ContentError error={tables.error} retry={() => void tables.refetch()} />
      <ContentError error={create.error} />
      {tables.isPending ? (
        <ContentSkeleton variant="table" label={t('pod.content.loading_tables')} />
      ) : explicitMissingTable ? (
        <div
          role="alert"
          data-slot="missing-embed-table"
          className="space-y-2 rounded-control border border-border bg-layer-01 p-4 text-sm">
          <p className="font-medium text-foreground">
            {t('pod.content.embed_bound_table_missing', {
              defaultValue: 'The bound table was deleted or is inaccessible.'
            })}
          </p>
          {Boolean(embed?.configureInline || embed?.bindSavedView) && (tables.data?.tables.length ?? 0) > 0 && (
            <div className="flex flex-wrap items-center gap-2 pt-1">
              <span className="text-xs text-fg-secondary">
                {t('pod.content.rebind_embed_table', { defaultValue: 'Rebind to table:' })}
              </span>
              {tables.data!.tables.map(candidate => (
                <Button
                  key={candidate.id}
                  size="sm"
                  variant="outline"
                  onClick={() => {
                    setSelected(candidate.id)
                    if (embed?.inlineConfig && embed.configureInline) {
                      embed.configureInline({ type: embed.inlineConfig.type ?? 'chart' }, candidate.id)
                    } else if (embed?.bindSavedView) {
                      embed.bindSavedView('', candidate.id)
                    } else if (embed?.configureInline) {
                      embed.configureInline({}, candidate.id)
                    }
                  }}>
                  {candidate.name}
                </Button>
              ))}
            </div>
          )}
        </div>
      ) : tableID ? (
        <TableWorkspace
          key={tableID}
          tableID={tableID}
          page={detail}
          tables={tables.data!.tables}
          initialView={initialView}
          embed={embed}
          onSwitchEmbedTable={nextTableId => {
            setSelected(nextTableId)
            if (embed?.inlineConfig && embed.configureInline) {
              embed.configureInline({ type: embed.inlineConfig.type ?? 'chart' }, nextTableId)
            }
          }}
        />
      ) : (
        <p className="py-12 text-sm text-fg-tertiary">
          {t('pod.content.no_tables_yet_create_one_to_manage_your_records')}
        </p>
      )}
      <Dialog open={deleting} onOpenChange={next => !remove.isPending && setDeleting(next)}>
        <DialogContent className="pod-dialog" closeLabel={t('common.close')} showCloseButton={!remove.isPending}>
          <DialogTitle>{t('pod.content.delete_table')}</DialogTitle>
          <p>{t('pod.content.delete_table_confirmation')}</p>
          <ContentError error={remove.error} />
          <DialogFooter>
            <Button variant="ghost" disabled={remove.isPending} onClick={() => setDeleting(false)}>
              {t('pod.content.cancel')}
            </Button>
            <Button variant="destructive" disabled={remove.isPending} onClick={() => remove.mutate()}>
              {t('pod.content.delete_table')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  )
}

function TableWorkspace({
  tableID,
  page,
  tables,
  initialView,
  embed,
  onSwitchEmbedTable
}: {
  tableID: string
  page: PageDetail
  tables: BaseTable[]
  initialView?: string
  embed?: EmbedBridge
  onSwitchEmbedTable?(tableID: string): void
}) {
  const { t } = useTranslation()
  const { base } = useContent()
  const pageHref = usePageHref()
  const schema = useQuery(baseSchemaQuery(tableID))
  useSignals()
  const model = useModel(TableWorkspaceModel)
  model.load(initialView)
  const viewID = model.viewID.value,
    draft = model.draft.value,
    pageToken = model.pageToken.value,
    history = model.history.value,
    newRecord = model.newRecord.value
  const setNewRecord = (value: boolean) => {
    model.newRecord.value = value
  }
  const newRecordSaving = useRef(false)
  const viewSaving = useRef(false)
  const inlineDebounceTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const pendingInlineFlush = useRef<(() => void) | undefined>(undefined)
  const chartAutoSaveTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const pendingChartSave = useRef<{ viewId: string; config: ViewConfig } | undefined>(undefined)
  const chartSaveInFlight = useRef<Promise<void> | null>(null)
  const latestViewVersions = useRef<Map<string, number>>(new Map())
  const flushChartAutoSaveRef = useRef<() => void>(() => {})
  const [chartAutoSaveError, setChartAutoSaveError] = useState<unknown>(undefined)
  const [renamingView, setRenamingView] = useState<string>()
  const [deletingView, setDeletingView] = useState<BaseView>()
  const [copiedPageID, setCopiedPageID] = useState<string>()
  const chartControlsId = useId()
  const client = useQueryClient()

  if (schema.data?.views) {
    for (const v of schema.data.views) {
      const prev = latestViewVersions.current.get(v.id) ?? 0
      if (v.version > prev) {
        latestViewVersions.current.set(v.id, v.version)
      }
    }
  }

  const flushChartAutoSave = () => {
    if (chartAutoSaveTimer.current) {
      clearTimeout(chartAutoSaveTimer.current)
      chartAutoSaveTimer.current = undefined
    }
    const payload = pendingChartSave.current
    if (!payload) return
    pendingChartSave.current = undefined
    const execute = async () => {
      const targetVersion =
        latestViewVersions.current.get(payload.viewId) ??
        schema.data?.views.find(v => v.id === payload.viewId)?.version ??
        0
      try {
        const res = await baseHTTP.updateView(payload.viewId, { config: payload.config }, targetVersion)
        const nextVer =
          res && typeof res === 'object' && 'view' in res && res.view && typeof res.view.version === 'number'
            ? res.view.version
            : targetVersion + 1
        latestViewVersions.current.set(payload.viewId, nextVer)
        setChartAutoSaveError(undefined)
        const activeViewId = model.viewID.value || schema.data?.views[0]?.id
        if (activeViewId === payload.viewId && !pendingChartSave.current) {
          model.draft.value = undefined
        }
        await client.invalidateQueries({ queryKey: base.key(tableID) })
      } catch (error) {
        setChartAutoSaveError(error)
        await client.invalidateQueries({ queryKey: [...base.key(tableID), 'schema'] })
      }
    }
    const prev = chartSaveInFlight.current ?? Promise.resolve()
    chartSaveInFlight.current = prev.then(execute, execute)
  }
  flushChartAutoSaveRef.current = flushChartAutoSave

  useEffect(() => {
    return () => {
      if (inlineDebounceTimer.current) {
        clearTimeout(inlineDebounceTimer.current)
        inlineDebounceTimer.current = undefined
        pendingInlineFlush.current?.()
        pendingInlineFlush.current = undefined
      }
      if (chartAutoSaveTimer.current || pendingChartSave.current) {
        flushChartAutoSaveRef.current()
      }
    }
  }, [])

  const removeView = useMutation({
    mutationFn: (view: BaseView) => baseHTTP.removeView(view.id, view.version),
    onSuccess: async () => {
      model.select('')
      setDeletingView(undefined)
      await client.invalidateQueries({ queryKey: base.key(tableID) })
    }
  })
  const duplicateView = useMutation({
    mutationFn: (source: BaseView) =>
      baseHTTP.createView(tableID, {
        name: nextViewName(schema.data?.views ?? [], source.name),
        type: source.type,
        config: source.config
      }),
    onSuccess: async ({ view: created }) => {
      await client.invalidateQueries({ queryKey: base.key(tableID) })
      model.select(created.id)
      embed?.bindSavedView?.(created.id, tableID)
    },
    onError: error => toast.error(requestErrorMessage(contentError(error)))
  })
  const isInlineConfigEmbed = Boolean(embed?.inlineConfig)
  const canEditDocInline = Boolean(embed?.configureInline)
  const view = isInlineConfigEmbed
    ? undefined
    : viewID
      ? schema.data?.views.find(view => view.id === viewID)
      : schema.data?.views[0]
  const missingView = !!viewID && !view && !isInlineConfigEmbed
  const effectiveType: ViewType = isInlineConfigEmbed ? (embed!.inlineConfig!.type ?? 'grid') : (view?.type ?? 'grid')
  const fallback: BaseView = { id: '', name: viewLabels[effectiveType], type: effectiveType, config: {}, version: 0 }
  const configuration = parseViewConfig(draft?.config ?? embed?.inlineConfig ?? view?.config ?? {})
  const parsedConfig = configuration.success
    ? schema.data
      ? sanitizeViewConfig(configuration.data, schema.data.fields, effectiveType)
      : configuration.data
    : {}
  const effective: ConfiguredView = {
    ...(view ?? fallback),
    type: effectiveType,
    config: parsedConfig
  }
  const [embedControlsOpen, setEmbedControlsOpen] = useState<boolean>(() =>
    Boolean(isInlineConfigEmbed && isUnconfiguredChartSpec(effective.config))
  )
  const quietSingleChartEmbed = Boolean(embed) && effective.type === 'chart'
  const query: RecordQuery = {
    filter: effective.config.filter,
    sort: effective.config.sort,
    page_size: 100,
    page_token: pageToken
  }
  const writes = useRecordWrites(tableID)
  const stats = useAggregate(tableID, {
    filter: query.filter,
    metrics: [{ operation: 'count', alias: 'count' }]
  })
  const updateView = useMutation({
    mutationFn: ({ config, version }: { config: Record<string, unknown>; version: number }) =>
      view
        ? baseHTTP.updateView(view.id, { config }, version)
        : baseHTTP.createView(tableID, {
            name: nextViewName(schema.data?.views ?? [], viewLabels[effective.type]),
            type: effective.type,
            config
          }),
    onSuccess: async res => {
      if (view && res && typeof res === 'object' && 'view' in res && res.view && typeof res.view.version === 'number') {
        latestViewVersions.current.set(view.id, res.view.version)
      }
      setChartAutoSaveError(undefined)
      await client.invalidateQueries({ queryKey: base.key(tableID) })
      model.draft.value = undefined
    },
    onError: () => client.invalidateQueries({ queryKey: [...base.key(tableID), 'schema'] }),
    onSettled: () => {
      viewSaving.current = false
    }
  })
  const promoteInlineToSavedView = useMutation({
    mutationFn: () =>
      baseHTTP.createView(tableID, {
        name: nextViewName(schema.data?.views ?? [], viewLabels[effective.type]),
        type: effective.type,
        config: sanitizeViewConfig(effective.config, schema.data?.fields ?? [], effective.type)
      }),
    onSuccess: async ({ view: created }) => {
      await client.invalidateQueries({ queryKey: base.key(tableID) })
      model.draft.value = undefined
      model.select(created.id)
      embed?.bindSavedView?.(created.id, tableID)
    },
    onError: error => toast.error(requestErrorMessage(contentError(error)))
  })
  const editable = page.actions.includes('node_contribute')
  const schemaEditable = page.actions.includes('node_edit')
  const canConfigureChart = embed ? canEditDocInline || schemaEditable : schemaEditable
  const autoSaveChart = !embed && schemaEditable && effective.type === 'chart' && Boolean(view)
  const configure = (config: ViewConfig) => {
    if (viewSaving.current) return
    const next = schema.data ? sanitizeViewConfig(config, schema.data.fields, effective.type) : config
    model.resetPages()
    if (isInlineConfigEmbed && canEditDocInline) {
      model.configure(next, 0)
      if (inlineDebounceTimer.current) clearTimeout(inlineDebounceTimer.current)
      const flush = () => {
        embed!.configureInline!({ ...next, type: effective.type }, tableID)
        model.draft.value = undefined
      }
      pendingInlineFlush.current = flush
      inlineDebounceTimer.current = setTimeout(() => {
        inlineDebounceTimer.current = undefined
        pendingInlineFlush.current = undefined
        flush()
      }, 400)
    } else if (autoSaveChart && view) {
      const targetVersion = latestViewVersions.current.get(view.id) ?? view.version
      model.configure(next, targetVersion)
      setChartAutoSaveError(undefined)
      pendingChartSave.current = { viewId: view.id, config: next }
      if (chartAutoSaveTimer.current) clearTimeout(chartAutoSaveTimer.current)
      chartAutoSaveTimer.current = setTimeout(() => {
        flushChartAutoSaveRef.current()
      }, 600)
    } else {
      model.configure(next, view?.version ?? 0)
    }
  }
  const handleFieldCreated = (fieldID: string) => {
    if (effective.config.visible_fields && !effective.config.visible_fields.includes(fieldID)) {
      configure({ ...effective.config, visible_fields: [...effective.config.visible_fields, fieldID] })
    }
  }
  if (schema.error && !schema.data) return <ContentError error={schema.error} retry={() => void schema.refetch()} />
  if (!schema.data) return <ContentSkeleton variant="table" label={t('pod.content.loading_table_schema')} />
  if (!configuration.success || missingView) {
    return (
      <div role="alert" className="space-y-2 p-4">
        <p>{t('pod.content.cannot_display')}</p>
        {(canEditDocInline || !embed || missingView) && (
          <Button
            variant="outline"
            size="sm"
            onClick={() => {
              if (missingView) {
                model.select('')
                embed?.bindSavedView?.('', tableID)
              } else if (canEditDocInline) {
                embed!.configureInline!({ type: effective.type === 'chart' ? 'chart' : 'grid' }, tableID)
              } else {
                configure({})
              }
            }}>
            {t('pod.content.discard_view_changes')}
          </Button>
        )}
      </div>
    )
  }
  const sharedViewProps: Omit<ViewProps, 'records' | 'pending' | 'create' | 'update' | 'remove'> = {
    pageID: page.page.id,
    tableID,
    tables,
    fields: schema.data.fields,
    view: effective,
    editable,
    schemaEditable,
    canConfigureChart,
    chartControlsOpen: embed ? embedControlsOpen : true,
    chartControlsId,
    configure,
    configuring: updateView.isPending,
    onFieldCreated: handleFieldCreated
  }
  const copiedLocation = copiedPageID ? pageHref(copiedPageID) : undefined
  const showDraftBanner =
    Boolean(draft) &&
    !(isInlineConfigEmbed && canEditDocInline) &&
    !(autoSaveChart && !chartAutoSaveError) &&
    !quietSingleChartEmbed
  const currentTableObj = tables.find(item => item.id === tableID)
  return (
    <div className="pod-base-workspace min-w-0">
      {(!quietSingleChartEmbed || canConfigureChart) && (
        <div className="pod-base-toolbar">
          {quietSingleChartEmbed ? (
            <div className="pod-base-view-navigation gap-2">
              {isInlineConfigEmbed && canEditDocInline && tables.length > 1 && onSwitchEmbedTable ? (
                <DropdownMenu>
                  <DropdownMenuTrigger render={<Button size="sm" variant="ghost" className="font-medium" />}>
                    {currentTableObj?.name ?? t('pod.content.table')} ▾
                  </DropdownMenuTrigger>
                  <DropdownMenuContent>
                    {tables.map(candidate => (
                      <DropdownMenuItem key={candidate.id} onClick={() => onSwitchEmbedTable(candidate.id)}>
                        {candidate.name}
                      </DropdownMenuItem>
                    ))}
                  </DropdownMenuContent>
                </DropdownMenu>
              ) : currentTableObj ? (
                <span className="px-1.5 text-xs font-medium text-fg-secondary">{currentTableObj.name}</span>
              ) : null}
              {!isInlineConfigEmbed && view && (
                <span
                  data-slot="linked-chart-badge"
                  className="rounded-mini bg-layer-01 px-1.5 py-0.5 text-xs text-fg-secondary">
                  {t('pod.content.linked_view_badge', {
                    defaultValue: 'Linked · {$name}',
                    name: view.name
                  })}
                </span>
              )}
              {isInlineConfigEmbed && schemaEditable && embed?.bindSavedView && (
                <Button
                  size="sm"
                  variant="ghost"
                  disabled={promoteInlineToSavedView.isPending}
                  onClick={() => promoteInlineToSavedView.mutate()}>
                  {t('pod.content.save_as_shared_view', { defaultValue: 'Save as shared view' })}
                </Button>
              )}
            </div>
          ) : (
            <div className="pod-base-view-navigation">
              <nav aria-label={t('pod.content.data_view')} className="pod-base-views">
                {schema.data.views.map(item => {
                  const Icon = viewIcons[item.type]
                  if (renamingView === item.id) {
                    return (
                      <DefinitionName
                        key={item.id}
                        name={item.name}
                        label={t('pod.content.view_name')}
                        invalidateKey={base.key(tableID)}
                        save={name => baseHTTP.updateView(item.id, { name }, item.version)}
                        close={() => setRenamingView(undefined)}
                      />
                    )
                  }
                  const active = !isInlineConfigEmbed && item.id === effective.id
                  return (
                    <div key={item.id} className="inline-flex shrink-0 items-center gap-0.5">
                      <Button
                        size="sm"
                        variant={active ? 'outline' : 'ghost'}
                        className="pod-base-view"
                        aria-pressed={active}
                        disabled={updateView.isPending}
                        onDoubleClick={() => schemaEditable && setRenamingView(item.id)}
                        onClick={() => {
                          flushChartAutoSave()
                          model.select(item.id)
                          if (embed?.bindSavedView) {
                            embed.bindSavedView(item.id, tableID)
                          } else if (isInlineConfigEmbed && canEditDocInline) {
                            const config = parseViewConfig(item.config)
                            if (config.success) embed!.configureInline!({ ...config.data, type: item.type }, tableID)
                          }
                          model.draft.value = undefined
                          updateView.reset()
                          setNewRecord(false)
                          model.resetPages()
                        }}>
                        <Icon aria-hidden="true" />
                        <span>{item.name}</span>
                      </Button>
                      {schemaEditable && active && (
                        <DropdownMenu>
                          <DropdownMenuTrigger
                            render={
                              <Button size="icon-sm" variant="ghost" aria-label={t('pod.content.view_actions')} />
                            }>
                            ⋯
                          </DropdownMenuTrigger>
                          <DropdownMenuContent>
                            <DropdownMenuItem onClick={() => setRenamingView(item.id)}>
                              {t('pod.sidebar.rename')}
                            </DropdownMenuItem>
                            <DropdownMenuItem
                              disabled={duplicateView.isPending}
                              onClick={() => duplicateView.mutate(item)}>
                              {t('pod.content.duplicate_view', { defaultValue: 'Duplicate view' })}
                            </DropdownMenuItem>
                            <DropdownMenuItem
                              variant="destructive"
                              disabled={schema.data.views.length <= 1}
                              onClick={() => {
                                removeView.reset()
                                setDeletingView(item)
                              }}>
                              {t('pod.content.delete_view')}
                            </DropdownMenuItem>
                          </DropdownMenuContent>
                        </DropdownMenu>
                      )}
                    </div>
                  )
                })}
              </nav>
              {schemaEditable && (
                <CreateViewButton
                  tableID={tableID}
                  fields={schema.data.fields}
                  views={schema.data.views}
                  onCreated={id => {
                    flushChartAutoSave()
                    model.select(id)
                    embed?.bindSavedView?.(id, tableID)
                  }}
                />
              )}
            </div>
          )}
          <div className="pod-base-tools">
            {quietSingleChartEmbed && !isInlineConfigEmbed && draft && (
              <>
                {schemaEditable && (
                  <Button
                    variant="default"
                    size="xs"
                    disabled={updateView.isPending || schema.isFetching}
                    onClick={() => {
                      if (viewSaving.current) return
                      viewSaving.current = true
                      updateView.mutate({
                        config: sanitizeViewConfig(draft.config, schema.data.fields, effective.type),
                        version: updateView.error ? (view?.version ?? 0) : draft.version
                      })
                    }}>
                    {updateView.isPending ? t('pod.content.saving_view') : t('pod.content.save_view_for_everyone')}
                  </Button>
                )}
                {canEditDocInline && (
                  <Button
                    variant={schemaEditable ? 'outline' : 'default'}
                    size="xs"
                    disabled={updateView.isPending}
                    onClick={() => {
                      const next = sanitizeViewConfig(draft.config, schema.data.fields, effective.type)
                      embed!.configureInline!({ ...next, type: effective.type }, tableID)
                      model.discard()
                      updateView.reset()
                    }}>
                    {t('pod.content.detach_as_doc_chart', { defaultValue: 'Detach as doc chart' })}
                  </Button>
                )}
                <Button
                  size="xs"
                  variant="ghost"
                  disabled={updateView.isPending}
                  onClick={() => {
                    model.discard()
                    updateView.reset()
                  }}>
                  {t('pod.content.discard_view_changes')}
                </Button>
              </>
            )}
            <QueryControls
              pageID={page.page.id}
              fields={schema.data.fields}
              filter={query.filter}
              sort={query.sort}
              disabled={updateView.isPending}
              update={(filter, sort) => configure({ ...effective.config, filter, sort })}
            />
            {quietSingleChartEmbed && canConfigureChart && (
              <Button
                size="sm"
                variant={embedControlsOpen ? 'default' : 'outline'}
                aria-expanded={embedControlsOpen}
                aria-controls={chartControlsId}
                onClick={() => setEmbedControlsOpen(prev => !prev)}>
                <RiEqualizerLine aria-hidden="true" />
                {t('pod.content.configure_chart', { defaultValue: 'Configure' })}
              </Button>
            )}
            {effective.type !== 'chart' && (
              <Popover>
                <PopoverTrigger render={<Button size="sm" variant="outline" />}>
                  {t('pod.content.fields')}
                </PopoverTrigger>
                <PopoverContent
                  align="end"
                  collisionPadding={16}
                  className="max-h-[min(24rem,calc(var(--available-height)-0.5rem))] w-64 gap-2 overflow-hidden p-3">
                  <PopoverTitle className="shrink-0">{t('pod.content.fields')}</PopoverTitle>
                  <div className="min-h-0 flex-1 grid gap-1 overflow-y-auto">
                    {schema.data.fields.map(field => {
                      const Icon = fieldIcons[field.type]
                      const checked =
                        field.is_primary ||
                        !effective.config.visible_fields ||
                        effective.config.visible_fields.includes(field.id)
                      return (
                        <div
                          key={field.id}
                          className="flex items-center gap-1 rounded-control px-1.5 py-1 hover:bg-accent/60">
                          <label className="flex min-w-0 flex-1 cursor-pointer items-center gap-2 text-sm">
                            <Checkbox
                              checked={checked}
                              disabled={field.is_primary || updateView.isPending}
                              onCheckedChange={next => {
                                const visible = effective.config.visible_fields
                                  ? schema
                                      .data!.fields.filter(
                                        item => item.is_primary || effective.config.visible_fields!.includes(item.id)
                                      )
                                      .map(item => item.id)
                                  : schema.data!.fields.map(item => item.id)
                                configure({
                                  ...effective.config,
                                  visible_fields: next
                                    ? [...new Set([...visible, field.id])]
                                    : visible.filter(id => id !== field.id)
                                })
                              }}
                            />
                            <Icon aria-hidden="true" className="size-3.5 shrink-0 text-fg-tertiary" />
                            <span className="truncate">{field.name}</span>
                          </label>
                          {schemaEditable && (
                            <FieldEditorButton
                              tableID={tableID}
                              pageID={page.page.id}
                              tables={tables}
                              field={field}
                              canManage={schemaEditable}
                              iconOnly
                            />
                          )}
                        </div>
                      )
                    })}
                  </div>
                  {schemaEditable && (
                    <div className="shrink-0 border-t border-border pt-2">
                      <FieldEditorButton
                        tableID={tableID}
                        pageID={page.page.id}
                        tables={tables}
                        canManage
                        onCreated={handleFieldCreated}
                      />
                    </div>
                  )}
                </PopoverContent>
              </Popover>
            )}
            {editable && !quietSingleChartEmbed && (
              <Button variant="default" size="sm" className="pod-base-new" onClick={() => setNewRecord(true)}>
                <RiAddLine aria-hidden="true" />
                {t('pod.content.new_record')}
              </Button>
            )}
            {!quietSingleChartEmbed && (
              <CopyTableButton
                tableID={tableID}
                parentID={page.page.parent_id ?? undefined}
                filter={query.filter}
                onCopied={setCopiedPageID}
              />
            )}
          </div>
        </div>
      )}
      {copiedLocation && (
        <div className="mt-2 flex items-center justify-between gap-2 rounded-control border border-border bg-muted/50 px-3 py-2 text-sm">
          <p role="status">
            {t('pod.content.copied_to_an_independent_page')}{' '}
            <a className="link" href={copiedLocation}>
              {t('pod.content.open_page')}
            </a>
          </p>
          <Button
            type="button"
            size="icon-xs"
            variant="ghost"
            aria-label={t('common.close')}
            title={t('common.close')}
            onClick={() => setCopiedPageID(undefined)}>
            <RiCloseLine aria-hidden="true" />
          </Button>
        </div>
      )}
      {showDraftBanner && draft && (
        <div className="pod-base-draft flex flex-wrap items-center gap-2 p-2 text-sm">
          <p role="status">
            {(!isInlineConfigEmbed && schemaEditable) || (!isInlineConfigEmbed && canEditDocInline)
              ? t('pod.content.view_settings_have_not_been_saved')
              : t('pod.content.filters_and_layout_apply_only_to_this_preview')}
          </p>
          {!isInlineConfigEmbed && schemaEditable && (
            <Button
              variant="default"
              size="sm"
              disabled={updateView.isPending || schema.isFetching}
              onClick={() => {
                if (viewSaving.current) return
                viewSaving.current = true
                updateView.mutate({
                  config: sanitizeViewConfig(draft.config, schema.data.fields, effective.type),
                  version: updateView.error || chartAutoSaveError ? (view?.version ?? 0) : draft.version
                })
              }}>
              {updateView.isPending
                ? t('pod.content.saving_view')
                : updateView.error || chartAutoSaveError
                  ? t('pod.content.save_these_settings_to_the_latest_view')
                  : t('pod.content.save_view_for_everyone')}
            </Button>
          )}
          {!isInlineConfigEmbed && canEditDocInline && (
            <Button
              variant={schemaEditable ? 'outline' : 'default'}
              size="sm"
              disabled={updateView.isPending}
              onClick={() => {
                const next = sanitizeViewConfig(draft.config, schema.data.fields, effective.type)
                embed!.configureInline!({ ...next, type: effective.type }, tableID)
                model.discard()
                updateView.reset()
              }}>
              {t('pod.content.save_inline_copy_in_doc', { defaultValue: 'Save as inline copy in document' })}
            </Button>
          )}
          <Button
            size="sm"
            variant="ghost"
            disabled={updateView.isPending}
            onClick={() => {
              setChartAutoSaveError(undefined)
              model.discard()
              updateView.reset()
            }}>
            {t('pod.content.discard_view_changes')}
          </Button>
        </div>
      )}
      {effective.type === 'kanban' || effective.type === 'chart' ? (
        <>
          <ContentError
            error={writes.write.error || updateView.error || chartAutoSaveError || stats.error || schema.error}
          />
          <div className="pod-base-content min-w-0">
            <ErrorBoundary variant="panel" resetKeys={[tableID, effective.id, effective.type]}>
              <BaseViewContent
                key={`${effective.id}:${effective.type}`}
                {...sharedViewProps}
                records={[]}
                pending={writes.write.isPending}
                create={writes.create}
                update={writes.update}
                remove={writes.remove}
              />
            </ErrorBoundary>
          </div>
          {!quietSingleChartEmbed && (
            <p className="pod-base-status text-xs text-fg-tertiary" role="status">
              {stats.isPending
                ? t('pod.content.loading_records')
                : t('pod.content.records', {
                    value1: stats.data?.groups[0]?.metrics.count ?? 0
                  })}
              {writes.write.isPending ? t('pod.content.saving_2') : ''}
            </p>
          )}
          {effective.type !== 'chart' && (
            <ErrorBoundary fallback={null} resetKeys={[tableID]}>
              <BaseSummary tableID={tableID} fields={schema.data.fields} filter={query.filter} />
            </ErrorBoundary>
          )}
        </>
      ) : (
        <UngroupedWorkspaceBody
          tableID={tableID}
          query={query}
          mode={schema.data.mode}
          sharedViewProps={sharedViewProps}
          statsCount={stats.data?.groups[0]?.metrics.count}
          upstreamError={updateView.error || stats.error || schema.error}
          historyLength={history.length}
          onPrevious={() => model.previous()}
          onNext={token => model.next(token)}
          summary={
            <ErrorBoundary fallback={null} resetKeys={[tableID]}>
              <BaseSummary tableID={tableID} fields={schema.data.fields} filter={query.filter} />
            </ErrorBoundary>
          }
        />
      )}
      <Dialog open={!!deletingView} onOpenChange={open => !open && !removeView.isPending && setDeletingView(undefined)}>
        <DialogContent closeLabel={t('common.close')}>
          <DialogTitle>{t('pod.content.delete_view')}</DialogTitle>
          <p>{deletingView?.name}</p>
          <ContentError error={removeView.error} />
          <DialogFooter>
            <Button variant="ghost" disabled={removeView.isPending} onClick={() => setDeletingView(undefined)}>
              {t('pod.content.cancel')}
            </Button>
            <Button
              variant="destructive"
              disabled={removeView.isPending}
              onClick={() => deletingView && removeView.mutate(deletingView)}>
              {t('pod.content.delete_view')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <Dialog
        open={newRecord}
        onOpenChange={next => {
          if (!newRecordSaving.current) setNewRecord(next)
        }}>
        <DialogContent
          className="pod-dialog pod-record-dialog"
          closeLabel={t('common.close')}
          showCloseButton={!writes.write.isPending}>
          <DialogTitle>{t('pod.content.new_record')}</DialogTitle>
          <ErrorBoundary variant="panel" resetKeys={[tableID, newRecord]}>
            <RecordForm
              fields={schema.data.fields}
              pageID={page.page.id}
              editable={editable}
              close={() => setNewRecord(false)}
              write={async changes => {
                newRecordSaving.current = true
                try {
                  await writes.write.mutateAsync(changes)
                  setNewRecord(false)
                } finally {
                  newRecordSaving.current = false
                }
              }}
            />
          </ErrorBoundary>
        </DialogContent>
      </Dialog>
    </div>
  )
}

function UngroupedWorkspaceBody({
  tableID,
  query,
  mode,
  sharedViewProps,
  statsCount,
  upstreamError,
  historyLength,
  onPrevious,
  onNext,
  summary
}: {
  tableID: string
  query: RecordQuery
  mode: string
  sharedViewProps: Omit<ViewProps, 'records' | 'pending' | 'create' | 'update' | 'remove'>
  statsCount: unknown
  upstreamError: unknown
  historyLength: number
  onPrevious(): void
  onNext(token: string): void
  summary: React.ReactNode
}) {
  const { t } = useTranslation()
  const records = useRecords(tableID, query)
  const rows = records.data?.records ?? []
  return (
    <>
      <ContentError
        error={records.error || records.write.error || upstreamError}
        retry={() => void records.refetch()}
      />
      <div className="pod-base-content min-w-0">
        <ErrorBoundary variant="panel" resetKeys={[tableID, sharedViewProps.view.id, sharedViewProps.view.type]}>
          <BaseViewContent
            key={`${sharedViewProps.view.id}:${sharedViewProps.view.type}`}
            {...sharedViewProps}
            records={rows}
            pending={records.write.isPending}
            create={records.create}
            update={records.update}
            remove={records.remove}
          />
        </ErrorBoundary>
        {!records.isPending && !records.error && !rows.length && (
          <p className="py-8 text-sm text-fg-tertiary">
            {sharedViewProps.editable
              ? t('pod.content.this_view_has_no_records_adjust_the_filters_or_add')
              : t('pod.content.this_view_has_no_records_adjust_the_filters')}
          </p>
        )}
      </div>
      <p className="pod-base-status text-xs text-fg-tertiary" role="status">
        {records.isPending
          ? t('pod.content.loading_records')
          : t('pod.content.records', {
              value1: statsCount ?? rows.length
            })}
        {records.write.isPending ? t('pod.content.saving_2') : ''}
      </p>
      {summary}
      {(mode === 'remote' || !!records.data?.page_token || historyLength > 0) && (
        <div className="pod-base-pagination flex items-center gap-2">
          <Button size="sm" variant="outline" disabled={!historyLength || records.isFetching} onClick={onPrevious}>
            {t('pod.content.previous_page')}
          </Button>
          <Button
            size="sm"
            variant="outline"
            disabled={!records.data?.page_token || records.isFetching}
            onClick={() => {
              if (records.data?.page_token) onNext(records.data.page_token)
            }}>
            {t('pod.content.next_page')}
          </Button>
        </div>
      )}
    </>
  )
}

function DefinitionName({
  name,
  label,
  invalidateKey,
  save,
  close
}: {
  name: string
  label: string
  invalidateKey: readonly unknown[]
  save(name: string): Promise<unknown>
  close(): void
}) {
  const [draft, setDraft] = useState(name)
  const writing = useRef(false)
  const client = useQueryClient()
  const write = useMutation({
    mutationFn: () => save(draft.trim()),
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: invalidateKey })
      close()
    },
    onError: error => toast.error(requestErrorMessage(contentError(error))),
    onSettled: () => {
      writing.current = false
    }
  })
  const commit = () => {
    if (writing.current) return
    if (!draft.trim() || draft.trim() === name) {
      close()
      return
    }
    writing.current = true
    write.mutate()
  }
  return (
    <Input
      className="h-7 w-40 px-2 text-sm"
      autoFocus
      aria-label={label}
      value={draft}
      disabled={write.isPending}
      onFocus={event => event.target.select()}
      onChange={event => setDraft(event.target.value)}
      onBlur={commit}
      onKeyDown={event => {
        if (event.nativeEvent.isComposing) return
        if (event.key === 'Enter') {
          event.preventDefault()
          commit()
        }
        if (event.key === 'Escape') {
          event.preventDefault()
          writing.current = true
          close()
        }
      }}
    />
  )
}

function CreateViewButton({
  tableID,
  fields,
  views,
  onCreated
}: {
  tableID: string
  fields: BaseField[]
  views: BaseView[]
  onCreated(id: string): void
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const { base } = useContent()
  const create = useMutation({
    mutationFn: (type: ViewType) => {
      const group =
        type === 'kanban' ? fields.find(field => field.type === 'select' && !field.config.multiple) : undefined
      const initialConfig: Record<string, unknown> =
        type === 'chart'
          ? serializeResolvedToViewConfig({}, deriveDefaultChartSpec(fields))
          : group
            ? { group_field_id: group.id }
            : {}
      return baseHTTP.createView(tableID, {
        name: nextViewName(views, viewLabels[type]),
        type,
        config: initialConfig
      })
    },
    onSuccess: async ({ view }) => {
      await client.invalidateQueries({ queryKey: base.key(tableID) })
      onCreated(view.id)
    },
    onError: error => toast.error(requestErrorMessage(contentError(error)))
  })
  return (
    <DropdownMenu>
      <DropdownMenuTrigger render={<Button size="sm" variant="ghost" disabled={create.isPending} />}>
        {t('pod.content.view')}
      </DropdownMenuTrigger>
      <DropdownMenuContent>
        {(Object.keys(viewLabels) as ViewType[]).map(type => {
          const Icon = viewIcons[type]
          return (
            <DropdownMenuItem key={type} disabled={create.isPending} onClick={() => create.mutate(type)}>
              <Icon aria-hidden="true" />
              {viewLabels[type]}
            </DropdownMenuItem>
          )
        })}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

function CopyTableButton({
  tableID,
  parentID,
  filter,
  onCopied
}: {
  tableID: string
  parentID?: string
  filter?: Filter
  onCopied(pageID: string): void
}) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false),
    [title, setTitle] = useState(''),
    [selectedParent, setParent] = useState<string>()
  const client = useQueryClient()
  const saving = useRef(false)
  const titleInput = useRef<HTMLInputElement>(null)
  const [selectedTarget, setSelectedTarget] = useState<Page>()
  const openDialog = () => {
    copy.reset()
    setTitle('')
    setParent(undefined)
    setSelectedTarget(undefined)
    setOpen(true)
  }
  const destinations = useQuery({
    ...pageSearchQuery('', { required_action: 'node_edit' }),
    enabled: open
  })
  const initialTarget = useQuery({ ...pageQuery(parentID ?? ''), enabled: open && Boolean(parentID) })
  const targets = [
    ...new Map(
      [
        ...(destinations.data?.pages ?? []),
        ...(initialTarget.data?.actions.includes('node_edit')
          ? [{ ...initialTarget.data.page, role: initialTarget.data.role, actions: initialTarget.data.actions }]
          : []),
        ...(selectedTarget ? [selectedTarget] : [])
      ].map(page => [page.id, page])
    ).values()
  ]
  const loadingTargets = destinations.isPending || (Boolean(parentID) && !selectedParent && initialTarget.isPending)
  const canCreateSpace = destinations.data?.can_create_space === true
  const canCreatePrivate = destinations.data?.can_create_private === true && !!destinations.data.principal_uid
  const parent = selectedParent ?? parentID ?? (canCreateSpace ? 'space' : canCreatePrivate ? 'private' : '')
  const invalidTarget =
    parent === 'space'
      ? !canCreateSpace
      : parent === 'private'
        ? !canCreatePrivate
        : !targets.some(page => page.id === parent)
  const copy = useMutation({
    mutationFn: () =>
      podBaseCopy({
        path: { id: tableID },
        body: {
          data: {
            parent_id: parent === 'space' || parent === 'private' ? null : parent,
            private_owner_uid: parent === 'private' ? destinations.data!.principal_uid : null,
            title: title.trim() || undefined,
            filter
          }
        }
      }),
    onSuccess: ({ page }) => {
      pageCreated(client, page)
      onCopied(page.id)
      setOpen(false)
    },
    onSettled: () => {
      saving.current = false
    }
  })
  return (
    <Dialog
      open={open}
      onOpenChange={next => {
        if (saving.current) return
        if (next) openDialog()
        else setOpen(false)
      }}>
      <Button size="icon-sm" variant="ghost" title={t('pod.content.copy_current_results')} onClick={openDialog}>
        <RiFileCopyLine aria-hidden="true" />
        <span className="sr-only">{t('pod.content.copy_current_results')}</span>
      </Button>
      <DialogContent
        className="pod-dialog"
        closeLabel={t('common.close')}
        showCloseButton={!copy.isPending}
        initialFocus={titleInput}
        aria-busy={copy.isPending}
        render={
          <form
            onSubmit={event => {
              event.preventDefault()
              if (saving.current || loadingTargets || invalidTarget || destinations.isError || !destinations.data) {
                return
              }
              saving.current = true
              copy.mutate()
            }}
          />
        }>
        <DialogTitle>{t('pod.content.copy_table')}</DialogTitle>
        <div className="pod-dialog-body grid gap-3">
          <p className="text-sm text-fg-tertiary">
            {t('pod.content.the_copied_data_is_saved_independently_changes_to_the_source')}
          </p>
          <label className="grid gap-2 text-sm">
            <span>{t('pod.content.page_title')}</span>
            <Input
              ref={titleInput}
              autoFocus
              aria-label={t('pod.content.page_title')}
              value={title}
              disabled={copy.isPending}
              onChange={event => setTitle(limitPageTitle(event.target.value, title))}
            />
          </label>
          <PagePicker
            label={t('pod.content.save_to')}
            requiredAction="node_edit"
            selected={parent}
            disabled={copy.isPending}
            autoFocus={false}
            roots={[
              ...(canCreateSpace ? [{ id: 'space', title: t('pod.content.space') }] : []),
              ...(canCreatePrivate ? [{ id: 'private', title: t('pod.content.private'), private: true }] : [])
            ]}
            onSelect={(id, page) => {
              setParent(id)
              setSelectedTarget(page)
            }}
          />
          <p className="pod-selected-destination text-sm">
            {loadingTargets
              ? t('pod.content.loading_destinations')
              : invalidTarget
                ? t('pod.content.the_original_destination_is_no_longer_editable_choose_another_destination')
                : `${t('pod.content.save_to')}: ${parent === 'space' ? t('pod.content.space') : parent === 'private' ? t('pod.content.private') : targets.find(page => page.id === parent)?.title || t('pod.content.untitled')}`}
          </p>
          <ContentError error={copy.error || destinations.error} />
        </div>
        <DialogFooter>
          <Button type="button" variant="ghost" disabled={copy.isPending} onClick={() => setOpen(false)}>
            {t('pod.content.cancel')}
          </Button>
          <Button
            variant="default"
            type="submit"
            disabled={copy.isPending || loadingTargets || destinations.isError || invalidTarget}>
            {t('pod.content.copy')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
