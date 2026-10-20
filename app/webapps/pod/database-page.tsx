import { createAppletRoutes } from './applet-routes'
import { t } from 'i18next'
import { AppletRuntimeProvider, useAggregate, useRecords } from '@ankole/applet-sdk'
import type { AppletRuntime, DatabaseTable, DatabaseView, Filter, ViewType } from '@ankole/applet-sdk/types'
import { Button, Dialog, DialogContent, DialogFooter, DialogTitle } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { TableWorkspaceModel } from './state/table-workspace'
import { parseViewConfig, type ViewConfig, type ConfiguredView } from './state/view-config'
import { useMemo, useRef, useState } from 'react'
import { RiAddLine, RiFileCopyLine, RiGalleryLine, RiLayoutColumnLine, RiTableLine } from '@remixicon/react'
import { contentKeys, podRequest, type PageDetail } from './content-api'
import { useContent } from './content-context'
import { Choice, ContentError, TextField } from './content-primitives'
import { databaseHTTP } from './database-api'
import { DatabaseViewContent, RecordForm } from './database-views'
import { QueryControls } from './database-query-controls'
import { FieldEditorButton } from './database-fields'
import { podDatabaseCopy } from '../common/api/generated/sdk.gen'
import { pageAPI } from './content-api'
import { DatabaseSummary } from './database-summary'
import './database.css'

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

export function DatabasePage({
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
  const { database, realtime } = useContent()
  const client = useQueryClient()
  const runtime = useMemo<AppletRuntime>(
    () => ({
      pageID: detail.page.id,
      instanceID: `database-${detail.page.id}`,
      revision: detail.page.revision,
      routes: createAppletRoutes(detail.page.id, detail.page.revision, () => {
        void client.invalidateQueries({ queryKey: contentKeys.page(detail.page.id) })
      }),
      queryClient: client,
      database,
      pod: { request: podRequest },
      channel: name => realtime.channel(detail.page.id, name),
      principal: realtime.principal
    }),
    [detail.page.id, detail.page.revision, client, database, realtime]
  )
  return (
    <AppletRuntimeProvider runtime={runtime}>
      <DatabaseWorkspace
        detail={detail}
        initialTable={tableID}
        initialView={viewID}
        inline={configureInline ? { config: inlineConfig, configure: configureInline } : undefined}
      />
    </AppletRuntimeProvider>
  )
}

function DatabaseWorkspace({
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
  const tables = useQuery({
    queryKey: [...contentKeys.page(detail.page.id), 'tables'],
    queryFn: () => databaseHTTP.tables(detail.page.id)
  })
  const [selected, setSelected] = useState(initialTable ?? '')
  const [name, setName] = useState('')
  const [creating, setCreating] = useState(false)
  const tableSaving = useRef(false)
  const client = useQueryClient()
  const create = useMutation({
    mutationFn: () => databaseHTTP.createTable(detail.page.id, name),
    onSuccess: async ({ table }) => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      setSelected(table.id)
      setName('')
      setCreating(false)
    },
    onSettled: () => {
      tableSaving.current = false
    }
  })
  const tableID = tables.data?.tables.some(table => table.id === selected) ? selected : tables.data?.tables[0]?.id
  return (
    <section className="pod-database min-w-0" data-inline={!!inline}>
      <div className="pod-database-sources" aria-label={t('pod.content.table')}>
        {tables.data?.tables.map(table => (
          <Button
            key={table.id}
            size="sm"
            variant="ghost"
            className={table.id === tableID ? 'font-semibold' : undefined}
            aria-pressed={table.id === tableID}
            onClick={() => {
              setSelected(table.id)
              inline?.configure({}, table.id)
            }}>
            {table.name}
          </Button>
        ))}
        {detail.role !== 'view' && (
          <Button size="sm" variant="ghost" onClick={() => setCreating(true)}>
            {t('pod.content.table_2')}
          </Button>
        )}
      </div>
      <ContentError error={tables.error} retry={() => void tables.refetch()} />
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
      <Dialog
        open={creating}
        onOpenChange={next => {
          if (!tableSaving.current) setCreating(next)
        }}>
        <DialogContent
          className="pod-dialog"
          closeLabel={t('common.close')}
          showCloseButton={!create.isPending}
          aria-busy={create.isPending}
          render={
            <form
              onSubmit={event => {
                event.preventDefault()
                if (tableSaving.current || !name.trim()) return
                tableSaving.current = true
                create.mutate()
              }}
            />
          }>
          <DialogTitle>{t('pod.content.new_table')}</DialogTitle>
          <TextField label={t('pod.content.table_name')} value={name} onChange={setName} disabled={create.isPending} />
          <ContentError error={create.error} />
          <DialogFooter>
            <Button type="button" variant="ghost" disabled={create.isPending} onClick={() => setCreating(false)}>
              {t('pod.content.cancel')}
            </Button>
            <Button variant="outline" type="submit" disabled={!name.trim() || create.isPending}>
              {t('pod.content.create_table')}
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
  tables: DatabaseTable[]
  initialView?: string
  inline?: InlineView
}) {
  const { database } = useContent()
  const schema = useQuery({
    queryKey: [...database.key(tableID), 'schema'],
    queryFn: () => databaseHTTP.schema(tableID)
  })
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
  const client = useQueryClient()
  const view = viewID ? schema.data?.views.find(view => view.id === viewID) : schema.data?.views[0]
  const missingView = !!viewID && !view && !inline?.config
  const fallback: DatabaseView = { id: '', name: t('pod.content.grid'), type: 'grid', config: {}, version: 0 }
  const configuration = parseViewConfig(draft?.config ?? inline?.config ?? view?.config ?? {})
  const effective: ConfiguredView = {
    ...(view ?? fallback),
    type: inline?.config ? (inline.config.type ?? 'grid') : (view?.type ?? 'grid'),
    config: configuration.success ? configuration.data : {}
  }
  const query = {
    filter: effective.config.filter,
    sort: effective.config.sort,
    page_size: 100,
    page_token: pageToken
  }
  const records = useRecords(tableID, query)
  const stats = useAggregate(tableID, {
    filter: query.filter,
    metrics: [{ operation: 'count', alias: 'count' }]
  })
  const updateView = useMutation({
    mutationFn: ({ config, version }: { config: Record<string, unknown>; version: number }) =>
      view
        ? databaseHTTP.updateView(view.id, { config }, version)
        : databaseHTTP.createView(tableID, { name: t('pod.content.grid'), type: 'grid', config }),
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: database.key(tableID) })
      model.draft.value = undefined
    },
    onError: () => client.invalidateQueries({ queryKey: [...database.key(tableID), 'schema'] }),
    onSettled: () => {
      viewSaving.current = false
    }
  })
  const editable = page.role !== 'view'
  const configure = (config: ViewConfig) => {
    if (viewSaving.current) return
    model.resetPages()
    if (inline) inline.configure({ ...config, type: effective.type })
    else model.configure(config, view?.version ?? 0)
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
  const props = {
    pageID: page.page.id,
    tableID,
    tables,
    fields: schema.data.fields,
    records: records.data?.records ?? [],
    view: effective,
    editable,
    pending: records.write.isPending,
    update: records.update,
    remove: records.remove,
    create: records.create,
    configure,
    configuring: updateView.isPending
  }
  return (
    <div className="pod-database-workspace min-w-0">
      <div className="pod-database-toolbar">
        <div className="pod-database-view-navigation">
          <nav aria-label={t('pod.content.data_view')} className="pod-database-views">
            {schema.data.views.map(view => {
              const Icon = viewIcons[view.type]
              return (
                <Button
                  key={view.id}
                  size="sm"
                  variant={view.id === effective.id ? 'outline' : 'ghost'}
                  className="pod-database-view"
                  aria-pressed={view.id === effective.id}
                  disabled={updateView.isPending}
                  onClick={() => {
                    model.select(view.id)
                    if (inline) {
                      const config = parseViewConfig(view.config)
                      if (config.success) inline.configure({ ...config.data, type: view.type })
                    }
                    model.draft.value = undefined
                    updateView.reset()
                    setNewRecord(false)
                    model.resetPages()
                  }}>
                  <Icon aria-hidden="true" />
                  <span>{view.name}</span>
                </Button>
              )
            })}
          </nav>
          {editable && (
            <CreateViewButton
              tableID={tableID}
              onCreated={id => {
                model.select(id)
              }}
            />
          )}
        </div>
        <div className="pod-database-tools">
          <QueryControls
            pageID={page.page.id}
            fields={schema.data.fields}
            filter={query.filter}
            sort={query.sort}
            disabled={updateView.isPending}
            update={(filter, sort) => configure({ ...effective.config, filter, sort })}
          />
          {editable && (
            <>
              <Button variant="outline" size="sm" className="pod-database-new" onClick={() => setNewRecord(true)}>
                <RiAddLine aria-hidden="true" />
                {t('pod.content.new_record')}
              </Button>
              {effective.type !== 'grid' && (
                <FieldEditorButton tableID={tableID} pageID={page.page.id} tables={tables} canManage />
              )}
            </>
          )}
          <CopyTableButton tableID={tableID} parentID={page.page.parent_id ?? undefined} filter={query.filter} />
        </div>
      </div>
      {draft && !inline && (
        <div className="pod-database-draft flex flex-wrap items-center gap-2 p-2 text-sm">
          <p role="status">
            {editable
              ? t('pod.content.view_settings_have_not_been_saved')
              : t('pod.content.filters_and_layout_apply_only_to_this_preview')}
          </p>
          {editable && (
            <Button
              variant="outline"
              size="sm"
              disabled={updateView.isPending || schema.isFetching}
              onClick={() => {
                if (viewSaving.current) return
                viewSaving.current = true
                updateView.mutate({
                  config: draft.config,
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
      <ContentError
        error={records.error || records.write.error || updateView.error || stats.error || schema.error}
        retry={() => void records.refetch()}
      />
      <div className="pod-database-content min-w-0">
        <DatabaseViewContent key={`${effective.id}:${effective.type}`} {...props} />
        {!records.isPending && !records.error && !props.records.length && (
          <p className="py-8 text-sm text-fg-tertiary">
            {editable
              ? t('pod.content.this_view_has_no_records_adjust_the_filters_or_add')
              : t('pod.content.this_view_has_no_records_adjust_the_filters')}
          </p>
        )}
      </div>
      <p className="pod-database-status text-xs text-fg-tertiary" role="status">
        {records.isPending
          ? t('pod.content.loading_records')
          : t('pod.content.records', {
              value1: stats.data?.groups[0]?.metrics.count ?? records.data?.records.length ?? 0
            })}
        {records.write.isPending ? t('pod.content.saving_2') : ''}
      </p>
      <DatabaseSummary tableID={tableID} fields={schema.data.fields} filter={query.filter} />
      {(schema.data.mode === 'remote' || !!records.data?.page_token || history.length > 0) && (
        <div className="pod-database-pagination flex items-center gap-2">
          <Button
            size="sm"
            variant="outline"
            disabled={!history.length || records.isFetching}
            onClick={() => {
              model.previous()
            }}>
            {t('pod.content.previous_page')}
          </Button>
          <Button
            size="sm"
            variant="outline"
            disabled={!records.data?.page_token || records.isFetching}
            onClick={() => {
              if (records.data?.page_token) model.next(records.data.page_token)
            }}>
            {t('pod.content.next_page')}
          </Button>
        </div>
      )}
      <Dialog
        open={newRecord}
        onOpenChange={next => {
          if (!newRecordSaving.current) setNewRecord(next)
        }}>
        <DialogContent
          className="pod-dialog pod-record-dialog"
          closeLabel={t('common.close')}
          showCloseButton={!records.write.isPending}>
          <DialogTitle>{t('pod.content.new_record')}</DialogTitle>
          <RecordForm
            fields={props.fields}
            pageID={props.pageID}
            close={() => setNewRecord(false)}
            create={async data => {
              newRecordSaving.current = true
              try {
                await records.create(data)
                setNewRecord(false)
              } finally {
                newRecordSaving.current = false
              }
            }}
          />
        </DialogContent>
      </Dialog>
    </div>
  )
}

function CreateViewButton({ tableID, onCreated }: { tableID: string; onCreated(id: string): void }) {
  const [open, setOpen] = useState(false),
    [name, setName] = useState(''),
    [type, setType] = useState<ViewType>('grid')
  const client = useQueryClient()
  const { database } = useContent()
  const saving = useRef(false)
  const create = useMutation({
    mutationFn: () => databaseHTTP.createView(tableID, { name: name || viewLabels[type], type, config: {} }),
    onSuccess: async ({ view }) => {
      await client.invalidateQueries({ queryKey: database.key(tableID) })
      onCreated(view.id)
      setOpen(false)
      setName('')
    },
    onSettled: () => {
      saving.current = false
    }
  })
  return (
    <Dialog
      open={open}
      onOpenChange={next => {
        if (!saving.current) setOpen(next)
      }}>
      <Button size="sm" variant="ghost" onClick={() => setOpen(true)}>
        {t('pod.content.view')}
      </Button>
      <DialogContent
        className="pod-dialog"
        closeLabel={t('common.close')}
        showCloseButton={!create.isPending}
        aria-busy={create.isPending}
        render={
          <form
            onSubmit={event => {
              event.preventDefault()
              if (saving.current) return
              saving.current = true
              create.mutate()
            }}
          />
        }>
        <DialogTitle>{t('pod.content.new_view')}</DialogTitle>
        <TextField label={t('pod.content.view_name')} value={name} onChange={setName} disabled={create.isPending} />
        <Choice
          label={t('pod.content.view_type')}
          value={type}
          onChange={setType}
          options={viewLabels}
          disabled={create.isPending}
        />
        <ContentError error={create.error} />
        <DialogFooter>
          <Button type="button" variant="ghost" disabled={create.isPending} onClick={() => setOpen(false)}>
            {t('pod.content.cancel')}
          </Button>
          <Button variant="outline" type="submit" disabled={create.isPending}>
            {t('pod.content.create_view')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function CopyTableButton({ tableID, parentID, filter }: { tableID: string; parentID?: string; filter?: Filter }) {
  const { pageHref } = useContent()
  const [open, setOpen] = useState(false),
    [title, setTitle] = useState(''),
    [parent, setParent] = useState(parentID ?? ''),
    [createdPage, setCreatedPage] = useState<string>()
  const client = useQueryClient()
  const saving = useRef(false)
  const destinations = useQuery({
    queryKey: [...contentKeys.all, 'copy-targets'],
    enabled: open,
    queryFn: () => pageAPI.list('all')
  })
  const targets = (destinations.data?.pages ?? []).filter(
    page => page.type === 'doc' && (page.role === 'edit' || page.role === 'manage')
  )
  const invalidTarget = !!parent && !targets.some(page => page.id === parent)
  const copy = useMutation({
    mutationFn: () => podDatabaseCopy({ path: { id: tableID }, body: { parent_id: parent || null, title, filter } }),
    onSuccess: async ({ page }) => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      setCreatedPage(page.id)
      setOpen(false)
    },
    onSettled: () => {
      saving.current = false
    }
  })
  const createdLocation = createdPage ? pageHref(createdPage) : undefined
  return (
    <>
      <Dialog
        open={open}
        onOpenChange={next => {
          if (!saving.current) setOpen(next)
        }}>
        <Button
          size="icon-sm"
          variant="ghost"
          title={t('pod.content.copy_current_results')}
          onClick={() => {
            copy.reset()
            setParent(parentID ?? '')
            setOpen(true)
          }}>
          <RiFileCopyLine aria-hidden="true" />
          <span className="sr-only">{t('pod.content.copy_current_results')}</span>
        </Button>
        <DialogContent
          className="pod-dialog"
          closeLabel={t('common.close')}
          showCloseButton={!copy.isPending}
          aria-busy={copy.isPending}
          render={
            <form
              onSubmit={event => {
                event.preventDefault()
                if (saving.current || invalidTarget || destinations.isError || !destinations.data) return
                saving.current = true
                copy.mutate()
              }}
            />
          }>
          <DialogTitle>{t('pod.content.copy_table')}</DialogTitle>
          <p className="text-sm text-fg-tertiary">
            {t('pod.content.the_copied_data_is_saved_independently_changes_to_the_source')}
          </p>
          <TextField label={t('pod.content.page_title')} value={title} onChange={setTitle} disabled={copy.isPending} />
          <Choice
            label={t('pod.content.save_to')}
            value={parent}
            onChange={setParent}
            disabled={copy.isPending || destinations.isPending}
            options={{
              '': t('pod.content.space'),
              ...(invalidTarget
                ? {
                    [parent]: t('pod.content.the_original_destination_is_no_longer_editable_choose_another_destination')
                  }
                : {}),
              ...Object.fromEntries(targets.map(page => [page.id, page.title || t('pod.content.untitled')]))
            }}
          />
          <ContentError error={copy.error || destinations.error} />
          <DialogFooter>
            <Button type="button" variant="ghost" disabled={copy.isPending} onClick={() => setOpen(false)}>
              {t('pod.content.cancel')}
            </Button>
            <Button
              variant="outline"
              type="submit"
              disabled={copy.isPending || destinations.isPending || destinations.isError || invalidTarget}>
              {t('pod.content.copy')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      {createdLocation && (
        <p role="status" className="text-sm">
          {t('pod.content.copied_to_an_independent_page')}{' '}
          <a className="link" href={createdLocation}>
            {t('pod.content.open_page')}
          </a>
        </p>
      )}
    </>
  )
}
