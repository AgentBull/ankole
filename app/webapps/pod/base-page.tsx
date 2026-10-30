import { createAppletRoutes } from './applet-routes'
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
  toast
} from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { TableWorkspaceModel } from './state/table-workspace'
import { parseViewConfig, type ViewConfig, type ConfiguredView } from './state/view-config'
import { useMemo, useRef, useState } from 'react'
import {
  RiAddLine,
  RiCloseLine,
  RiFileCopyLine,
  RiGalleryLine,
  RiLayoutColumnLine,
  RiTableLine
} from '@remixicon/react'
import { contentKeys, podRequest, type PageDetail } from './content-api'
import { ErrorBoundary } from '../common/error-boundary'
import { useContent } from './content-context'
import { ContentError } from './content-primitives'
import { baseHTTP, baseTablesQuery, baseSchemaQuery } from './base-api'
import { BaseViewContent, RecordForm, fieldIcons, type ViewProps } from './base-views'
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
  }
}

const viewIcons = {
  grid: RiTableLine,
  kanban: RiLayoutColumnLine,
  gallery: RiGalleryLine
}

type InlineView = { config?: ViewConfig; configure(config: ViewConfig, table?: string): void }

export function BasePage({
  detail,
  tableID,
  viewID,
  inlineConfig,
  configureInline
}: {
  detail: PageDetail
  tableID?: string
  viewID?: string
  inlineConfig?: ViewConfig
  configureInline?: (config: ViewConfig, table?: string) => void
}) {
  const { base, realtime, readDenial } = useContent()
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
      pod: { request: podRequest },
      channel: name => realtime.channel(detail.page.id, name),
      principal: realtime.principal
    }),
    [detail.page.id, detail.page.revision, detail.actions, client, readDenial, base, realtime]
  )
  return (
    <AppletRuntimeProvider runtime={runtime}>
      <BaseWorkspace
        detail={detail}
        initialTable={tableID}
        initialView={viewID}
        inline={configureInline ? { config: inlineConfig, configure: configureInline } : undefined}
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

function sanitizeViewConfig(config: ViewConfig, fields: BaseField[]): ViewConfig {
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
  inline
}: {
  detail: PageDetail
  initialTable?: string
  initialView?: string
  inline?: InlineView
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
  const tableID = tables.data?.tables.some(table => table.id === selected) ? selected : tables.data?.tables[0]?.id
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
  const hasTableActions = detail.actions.includes('page_edit') || detail.actions.includes('page_manage')
  return (
    <section className="pod-base min-w-0" data-inline={!!inline}>
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
                onDoubleClick={() => detail.actions.includes('page_edit') && setRenaming(table.id)}
                onClick={() => {
                  setSelected(table.id)
                  inline?.configure({}, table.id)
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
                    {detail.actions.includes('page_edit') && (
                      <DropdownMenuItem onClick={() => setRenaming(table.id)}>
                        {t('pod.sidebar.rename')}
                      </DropdownMenuItem>
                    )}
                    {detail.actions.includes('page_manage') && (
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
        {detail.actions.includes('page_edit') && (
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
      <ContentError error={tables.error} retry={() => void tables.refetch()} />
      <ContentError error={create.error} />
      {tables.isPending ? (
        <p role="status">{t('pod.content.loading_tables')}</p>
      ) : tableID ? (
        <TableWorkspace
          key={tableID}
          tableID={tableID}
          page={detail}
          tables={tables.data!.tables}
          initialView={initialView}
          inline={inline}
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
  inline
}: {
  tableID: string
  page: PageDetail
  tables: BaseTable[]
  initialView?: string
  inline?: InlineView
}) {
  const { t } = useTranslation()
  const { base, pageHref } = useContent()
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
  const [renamingView, setRenamingView] = useState<string>()
  const [deletingView, setDeletingView] = useState<BaseView>()
  const [copiedPageID, setCopiedPageID] = useState<string>()
  const client = useQueryClient()
  const removeView = useMutation({
    mutationFn: (view: BaseView) => baseHTTP.removeView(view.id, view.version),
    onSuccess: async () => {
      model.select('')
      setDeletingView(undefined)
      await client.invalidateQueries({ queryKey: base.key(tableID) })
    }
  })
  const view = viewID ? schema.data?.views.find(view => view.id === viewID) : schema.data?.views[0]
  const missingView = !!viewID && !view && !inline?.config
  const fallback: BaseView = { id: '', name: t('pod.content.grid'), type: 'grid', config: {}, version: 0 }
  const configuration = parseViewConfig(draft?.config ?? inline?.config ?? view?.config ?? {})
  const parsedConfig = configuration.success
    ? schema.data
      ? sanitizeViewConfig(configuration.data, schema.data.fields)
      : configuration.data
    : {}
  const effective: ConfiguredView = {
    ...(view ?? fallback),
    type: inline?.config ? (inline.config.type ?? 'grid') : (view?.type ?? 'grid'),
    config: parsedConfig
  }
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
        : baseHTTP.createView(tableID, { name: t('pod.content.grid'), type: 'grid', config }),
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: base.key(tableID) })
      model.draft.value = undefined
    },
    onError: () => client.invalidateQueries({ queryKey: [...base.key(tableID), 'schema'] }),
    onSettled: () => {
      viewSaving.current = false
    }
  })
  const editable = page.actions.includes('page_write_records')
  const schemaEditable = page.actions.includes('page_edit')
  const configure = (config: ViewConfig) => {
    if (viewSaving.current) return
    const next = schema.data ? sanitizeViewConfig(config, schema.data.fields) : config
    model.resetPages()
    if (inline) inline.configure({ ...next, type: effective.type })
    else model.configure(next, view?.version ?? 0)
  }
  const handleFieldCreated = (fieldID: string) => {
    if (effective.config.visible_fields && !effective.config.visible_fields.includes(fieldID)) {
      configure({ ...effective.config, visible_fields: [...effective.config.visible_fields, fieldID] })
    }
  }
  if (schema.error && !schema.data) return <ContentError error={schema.error} retry={() => void schema.refetch()} />
  if (!schema.data) return <p role="status">{t('pod.content.loading_table_schema')}</p>
  if (!configuration.success || missingView) {
    return (
      <div role="alert" className="space-y-2 p-4">
        <p>{t('pod.content.cannot_display')}</p>
        <Button
          variant="outline"
          size="sm"
          onClick={() => {
            if (missingView) model.select('')
            if (inline) inline.configure({ type: 'grid' })
            else if (!missingView) configure({})
          }}>
          {t('pod.content.discard_view_changes')}
        </Button>
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
    configure,
    configuring: updateView.isPending,
    onFieldCreated: handleFieldCreated
  }
  const copiedLocation = copiedPageID ? pageHref(copiedPageID) : undefined
  return (
    <div className="pod-base-workspace min-w-0">
      <div className="pod-base-toolbar">
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
              const active = item.id === effective.id
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
                      model.select(item.id)
                      if (inline) {
                        const config = parseViewConfig(item.config)
                        if (config.success) inline.configure({ ...config.data, type: item.type })
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
                        render={<Button size="icon-sm" variant="ghost" aria-label={t('pod.content.view_actions')} />}>
                        ⋯
                      </DropdownMenuTrigger>
                      <DropdownMenuContent>
                        <DropdownMenuItem onClick={() => setRenamingView(item.id)}>
                          {t('pod.sidebar.rename')}
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
              onCreated={id => {
                model.select(id)
              }}
            />
          )}
        </div>
        <div className="pod-base-tools">
          <QueryControls
            pageID={page.page.id}
            fields={schema.data.fields}
            filter={query.filter}
            sort={query.sort}
            disabled={updateView.isPending}
            update={(filter, sort) => configure({ ...effective.config, filter, sort })}
          />
          <Popover>
            <PopoverTrigger render={<Button size="sm" variant="outline" />}>{t('pod.content.fields')}</PopoverTrigger>
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
          {editable && (
            <Button variant="default" size="sm" className="pod-base-new" onClick={() => setNewRecord(true)}>
              <RiAddLine aria-hidden="true" />
              {t('pod.content.new_record')}
            </Button>
          )}
          <CopyTableButton
            tableID={tableID}
            parentID={page.page.parent_id ?? undefined}
            filter={query.filter}
            onCopied={setCopiedPageID}
          />
        </div>
      </div>
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
      {draft && !inline && (
        <div className="pod-base-draft flex flex-wrap items-center gap-2 p-2 text-sm">
          <p role="status">
            {schemaEditable
              ? t('pod.content.view_settings_have_not_been_saved')
              : t('pod.content.filters_and_layout_apply_only_to_this_preview')}
          </p>
          {schemaEditable && (
            <Button
              variant="default"
              size="sm"
              disabled={updateView.isPending || schema.isFetching}
              onClick={() => {
                if (viewSaving.current) return
                viewSaving.current = true
                updateView.mutate({
                  config: sanitizeViewConfig(draft.config, schema.data.fields),
                  version: updateView.error ? (view?.version ?? 0) : draft.version
                })
              }}>
              {updateView.isPending
                ? t('pod.content.saving_view')
                : updateView.error
                  ? t('pod.content.save_these_settings_to_the_latest_view')
                  : t('pod.content.save_view_for_everyone')}
            </Button>
          )}
          <Button
            size="sm"
            variant="ghost"
            disabled={updateView.isPending}
            onClick={() => {
              model.discard()
              updateView.reset()
            }}>
            {t('pod.content.discard_view_changes')}
          </Button>
        </div>
      )}
      {effective.type === 'kanban' ? (
        <>
          <ContentError error={writes.write.error || updateView.error || stats.error || schema.error} />
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
          <p className="pod-base-status text-xs text-fg-tertiary" role="status">
            {stats.isPending
              ? t('pod.content.loading_records')
              : t('pod.content.records', {
                  value1: stats.data?.groups[0]?.metrics.count ?? 0
                })}
            {writes.write.isPending ? t('pod.content.saving_2') : ''}
          </p>
          <ErrorBoundary fallback={null} resetKeys={[tableID]}>
            <BaseSummary tableID={tableID} fields={schema.data.fields} filter={query.filter} />
          </ErrorBoundary>
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
  onCreated
}: {
  tableID: string
  fields: BaseField[]
  onCreated(id: string): void
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const { base } = useContent()
  const create = useMutation({
    mutationFn: (type: ViewType) => {
      const group =
        type === 'kanban' ? fields.find(field => field.type === 'select' && !field.config.multiple) : undefined
      return baseHTTP.createView(tableID, {
        name: viewLabels[type],
        type,
        config: group ? { group_field_id: group.id } : {}
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
    ...pageSearchQuery('', { required_action: 'page_edit' }),
    enabled: open
  })
  const initialTarget = useQuery({ ...pageQuery(parentID ?? ''), enabled: open && Boolean(parentID) })
  const targets = [
    ...new Map(
      [
        ...(destinations.data?.pages ?? []),
        ...(initialTarget.data?.actions.includes('page_edit')
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
              onChange={event => setTitle(event.target.value)}
            />
          </label>
          <PagePicker
            label={t('pod.content.save_to')}
            requiredAction="page_edit"
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
