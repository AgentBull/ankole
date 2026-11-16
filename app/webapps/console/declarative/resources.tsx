import {
  Button,
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  Input,
  TableCell,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  toast
} from '@ankole/uikit'
import { useParams } from '@tanstack/react-router'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ErrorBlock } from '../../common/error-block'
import { EditorNotFound, ResourceEditorPage, StatusIndicator } from '../console-form'
import { ResourceListPage, ResourceSearch, RowActions, RowViewAction, type RowAction } from '../console-list-page'
import { PageHeader, PageStack } from '../console-page'
import { Link, TableRow, useNavigate, useSearchParams } from '../tenant-context'
import { DeclarativeActionTrigger } from './actions'
import { DeclarativeFields, DeclarativeSelect } from './fields'
import { DeclarativeDashboardView, DeclarativeFacts, DeclarativePanelView, DeclarativeValue } from './panels'
import {
  asRecord,
  executeDeclarativeAction,
  formatIdentifierLabel,
  isRecord,
  resolveRecordEndpoint,
  serializeDeclarativeFields,
  surfaceQueryEndpoint,
  useDeclarativeRecords,
  useDeclarativeVisibility,
  type DeclarativeRecord
} from './transport'
import type {
  DeclarativeConsoleManifest,
  DeclarativeRouteSpec,
  DeclarativeRowActionDescriptor,
  DeclarativeSurfaceDescriptor
} from './types'
import { DeclarativeWizardTrigger } from './wizard'

function normalizeRowAction(
  entry: DeclarativeRowActionDescriptor | string,
  surfaceById: ReadonlyMap<string, DeclarativeSurfaceDescriptor>
): DeclarativeRowActionDescriptor | null {
  if (typeof entry !== 'string') return entry
  const target = surfaceById.get(entry)
  if (!target) return null
  if (target.operationKind === 'delete' || target.method === 'DELETE') {
    return { kind: 'delete', actionId: entry, labelKey: target.titleKey }
  }
  if (target.editRoute) {
    return { kind: 'route', actionId: entry, labelKey: target.titleKey, routeTemplate: target.editRoute }
  }
  return { kind: 'modal', actionId: entry, labelKey: target.titleKey }
}

function buildRowPrefillPayload(
  actionSurface: DeclarativeSurfaceDescriptor,
  row: Readonly<Record<string, unknown>>
): Record<string, unknown> {
  const prefill: Record<string, unknown> = {}
  const recordId = row.id ?? row.request_id
  if (typeof recordId === 'string') prefill.id = recordId

  if (actionSurface.operationKind === 'update' || actionSurface.method === 'PATCH' || actionSurface.method === 'PUT') {
    for (const field of actionSurface.fields) {
      if (!field.readOnly && field.type !== 'secret' && field.name in row) {
        prefill[field.name] = row[field.name]
      }
    }
  }
  return prefill
}

export function DeclarativeResourceTable({
  surface,
  surfaceById,
  visibleIds,
  rows,
  loading = false,
  error,
  filters = {},
  i18nPrefix = 'console',
  detailSurfaceId,
  titleOverride,
  onChangeFilter,
  onClearFilters,
  onRefresh,
  onExecuteAction
}: {
  surface: DeclarativeSurfaceDescriptor
  surfaceById: ReadonlyMap<string, DeclarativeSurfaceDescriptor>
  visibleIds: ReadonlySet<string>
  rows: readonly DeclarativeRecord[]
  loading?: boolean
  error?: string | null
  filters?: Readonly<Record<string, string>>
  i18nPrefix?: string
  detailSurfaceId?: string
  titleOverride?: string
  onChangeFilter?: (name: string, value: string) => void
  onClearFilters?: () => void
  onRefresh: () => void
  onExecuteAction?: (
    targetSurface: DeclarativeSurfaceDescriptor,
    payload: Record<string, unknown>
  ) => Promise<readonly DeclarativeRecord[]>
}) {
  const { t } = useTranslation()
  const [selectedRow, setSelectedRow] = useState<DeclarativeRecord | null>(null)
  const [activeRowModal, setActiveRowModal] = useState<{
    action: DeclarativeSurfaceDescriptor
    payload: Record<string, unknown>
  } | null>(null)
  const [pendingActionKey, setPendingActionKey] = useState<string | null>(null)
  const [rowError, setRowError] = useState<string | null>(null)

  const runExecute = async (
    targetSurface: DeclarativeSurfaceDescriptor,
    payload: Record<string, unknown>
  ): Promise<readonly DeclarativeRecord[]> => {
    const res = onExecuteAction
      ? await onExecuteAction(targetSurface, payload)
      : await executeDeclarativeAction(targetSurface, payload)
    onRefresh()
    return res
  }

  const resolvedToolbarActions = (surface.toolbarActionIds ?? [])
    .map(id => surfaceById.get(id))
    .filter((item): item is DeclarativeSurfaceDescriptor => Boolean(item && visibleIds.has(item.surface)))

  const resolvedRowSpecs = (surface.rowActions ?? [])
    .map(entry => normalizeRowAction(entry, surfaceById))
    .filter((item): item is DeclarativeRowActionDescriptor => {
      if (!item) return false
      const target = surfaceById.get(item.actionId)
      return Boolean(target && visibleIds.has(target.surface))
    })

  const routeEditSpec = resolvedRowSpecs.find(
    (item): item is Extract<DeclarativeRowActionDescriptor, { kind: 'route' }> => item.kind === 'route'
  )

  const resolvedDetailSurfaceId = detailSurfaceId ?? surface.detailSurfaceId
  const detailSurface = resolvedDetailSurfaceId ? surfaceById.get(resolvedDetailSurfaceId) : undefined
  const canInspectDetail =
    Boolean(detailSurface && visibleIds.has(detailSurface.surface)) ||
    Boolean(surface.detailSurfaceId && !detailSurface)

  const searchFilterSchema = surface.filterSchemas?.find(schema => schema.name === 'search')
  const hasSearchFilter = Boolean(searchFilterSchema || surface.filters.includes('search'))
  const extraFilters = (surface.filterSchemas ?? []).filter(schema => schema.name !== 'search')
  const fallbackFilters = surface.filterSchemas
    ? []
    : surface.filters
        .filter(name => name !== 'search')
        .map(name => ({
          name,
          type: 'text' as const,
          labelKey: `${i18nPrefix}.field.${name}`
        }))
  const secondaryFilters = [...extraFilters, ...fallbackFilters]
  const isFiltered = Object.values(filters).some(Boolean)

  const columnHeaders = surface.columns.map(col =>
    t(`${i18nPrefix}.field.${col}`, { defaultValue: formatIdentifierLabel(col) })
  )

  const heading = titleOverride ?? t(surface.titleKey, { defaultValue: formatIdentifierLabel(surface.id) })

  return (
    <div className="grid gap-4">
      <ResourceListPage
        columns={columnHeaders}
        count={rows.length}
        createTo={surface.createRoute ?? undefined}
        emptyTitle={t('console.empty.title', { defaultValue: 'No records yet' })}
        error={error ?? rowError}
        isEmpty={rows.length === 0}
        isFiltered={isFiltered}
        isLoading={loading}
        title={heading}
        toolbar={
          hasSearchFilter || secondaryFilters.length > 0 || resolvedToolbarActions.length > 0 ? (
            <div className="flex w-full flex-wrap items-center gap-2">
              {hasSearchFilter && onChangeFilter ? (
                <ResourceSearch
                  filters={secondaryFilters.map(filterItem =>
                    filterItem.type === 'select' && filterItem.enumValues ? (
                      <DeclarativeSelect
                        key={filterItem.name}
                        label={t(filterItem.labelKey, { defaultValue: formatIdentifierLabel(filterItem.name) })}
                        options={[
                          ['', t('common.all', { defaultValue: 'All' })],
                          ...filterItem.enumValues.map(
                            val =>
                              [
                                val,
                                t(`${i18nPrefix}.value.${val}`, { defaultValue: formatIdentifierLabel(val) })
                              ] as const
                          )
                        ]}
                        value={filters[filterItem.name] ?? ''}
                        onChange={nextVal => onChangeFilter(filterItem.name, nextVal)}
                      />
                    ) : (
                      <Input
                        key={filterItem.name}
                        aria-label={t(filterItem.labelKey, { defaultValue: formatIdentifierLabel(filterItem.name) })}
                        className="w-36"
                        placeholder={t(filterItem.labelKey, { defaultValue: formatIdentifierLabel(filterItem.name) })}
                        type={filterItem.type === 'date' ? 'date' : 'text'}
                        value={filters[filterItem.name] ?? ''}
                        onChange={event => onChangeFilter(filterItem.name, event.target.value)}
                      />
                    )
                  )}
                  label={t(searchFilterSchema?.labelKey ?? `${i18nPrefix}.ui.search`, { defaultValue: 'Search' })}
                  placeholder={t(searchFilterSchema?.placeholderKey ?? `${i18nPrefix}.ui.search`, {
                    defaultValue: 'Search...'
                  })}
                  value={filters.search ?? ''}
                  onChange={next => onChangeFilter('search', next)}
                />
              ) : null}

              <div className="ml-auto flex flex-wrap items-center gap-2">
                {resolvedToolbarActions.map(action =>
                  action.kind === 'wizard' ? (
                    <DeclarativeWizardTrigger
                      key={action.id}
                      i18nPrefix={i18nPrefix}
                      surface={action}
                      onComplete={onRefresh}
                      onExecute={runExecute}
                    />
                  ) : (
                    <DeclarativeActionTrigger
                      key={action.id}
                      i18nPrefix={i18nPrefix}
                      payload={asRecord(action.initialFields)}
                      surface={action}
                      onExecute={runExecute}
                    />
                  )
                )}
              </div>
            </div>
          ) : undefined
        }
        toolbarCanRevealRows={resolvedToolbarActions.length > 0 || secondaryFilters.length > 0}
        onClearFilters={onClearFilters}>
        {rows.map((row, rowIndex) => {
          const rowId =
            typeof row.id === 'string' ? row.id : typeof row.request_id === 'string' ? row.request_id : undefined
          const editTo = routeEditSpec && rowId ? resolveRecordEndpoint(routeEditSpec.routeTemplate, rowId) : undefined
          const deleteSpec = resolvedRowSpecs.find(item => item.kind === 'delete')
          const deleteSurface = deleteSpec ? surfaceById.get(deleteSpec.actionId) : undefined

          const extraMenuActions: RowAction[] = resolvedRowSpecs.flatMap(spec => {
            if (spec.kind === 'route' || spec.kind === 'delete') return []
            const target = surfaceById.get(spec.actionId)
            if (!target) return []
            if (spec.kind === 'toggle_patch') {
              const inactive = spec.inactiveValues.includes(String(row[spec.field] ?? ''))
              const toggleKey = `${rowId ?? rowIndex}:${spec.actionId}`
              return [
                {
                  label: t(inactive ? spec.activateLabelKey : spec.deactivateLabelKey),
                  pending: pendingActionKey === toggleKey,
                  onAction: () => {
                    if (!rowId) return
                    setPendingActionKey(toggleKey)
                    setRowError(null)
                    void runExecute(target, {
                      id: rowId,
                      [spec.field]: inactive ? spec.activeValue : spec.inactiveValue
                    })
                      .catch((failure: unknown) =>
                        setRowError(failure instanceof Error ? failure.message : String(failure))
                      )
                      .finally(() => setPendingActionKey(null))
                  }
                }
              ]
            }
            return [
              {
                label: t(spec.labelKey ?? target.titleKey, { defaultValue: formatIdentifierLabel(target.id) }),
                onAction: () =>
                  setActiveRowModal({
                    action: target,
                    payload: buildRowPrefillPayload(target, row)
                  })
              }
            ]
          })

          return (
            <TableRow key={String(rowId ?? rowIndex)}>
              {surface.columns.map(col => (
                <TableCell key={col}>
                  {editTo && surface.linkedColumn === col ? (
                    <Link className="link" to={editTo}>
                      {String(row[col] ?? '')}
                    </Link>
                  ) : col === 'status' || col === 'state' || col === 'severity' ? (
                    <StatusIndicator
                      tone={
                        ['healthy', 'available', 'active', 'ok'].includes(String(row[col]))
                          ? 'positive'
                          : ['critical', 'error', 'banned', 'failed', 'paused'].includes(String(row[col]))
                            ? 'warning'
                            : 'neutral'
                      }>
                      <DeclarativeValue field={col} i18nPrefix={i18nPrefix} value={row[col]} />
                    </StatusIndicator>
                  ) : (
                    <DeclarativeValue field={col} i18nPrefix={i18nPrefix} value={row[col]} />
                  )}
                </TableCell>
              ))}

              {editTo && routeEditSpec ? (
                <RowActions
                  actions={extraMenuActions}
                  deleteConfirm={
                    deleteSurface
                      ? {
                          title: t(deleteSurface.titleKey, { defaultValue: 'Delete' }),
                          confirmLabel: t('common.delete', { defaultValue: 'Delete' })
                        }
                      : undefined
                  }
                  deletePending={Boolean(rowId && pendingActionKey === `${rowId}:delete`)}
                  editLabel={t(routeEditSpec.labelKey, { defaultValue: 'Edit' })}
                  editTo={editTo}
                  onDelete={
                    deleteSurface && rowId
                      ? () => {
                          setPendingActionKey(`${rowId}:delete`)
                          setRowError(null)
                          void runExecute(deleteSurface, { id: rowId })
                            .catch((failure: unknown) =>
                              setRowError(failure instanceof Error ? failure.message : String(failure))
                            )
                            .finally(() => setPendingActionKey(null))
                        }
                      : undefined
                  }
                />
              ) : canInspectDetail && resolvedRowSpecs.length === 0 ? (
                <RowViewAction
                  label={t('common.view', { defaultValue: 'Inspect' })}
                  onOpen={() => setSelectedRow(row)}
                />
              ) : (
                <TableCell className="text-right">
                  <div className="flex flex-wrap items-center justify-end gap-1">
                    {canInspectDetail ? (
                      <Button size="xs" type="button" variant="outline" onClick={() => setSelectedRow(row)}>
                        {t('common.view', { defaultValue: 'Inspect' })}
                      </Button>
                    ) : null}
                    {resolvedRowSpecs.map(spec => {
                      const target = surfaceById.get(spec.actionId)
                      if (!target) return null
                      return (
                        <DeclarativeActionTrigger
                          key={spec.actionId}
                          i18nPrefix={i18nPrefix}
                          label={t('labelKey' in spec && spec.labelKey ? spec.labelKey : target.titleKey, {
                            defaultValue: formatIdentifierLabel(target.id)
                          })}
                          payload={buildRowPrefillPayload(target, row)}
                          surface={target}
                          onExecute={runExecute}
                        />
                      )
                    })}
                  </div>
                </TableCell>
              )}
            </TableRow>
          )
        })}
      </ResourceListPage>

      {selectedRow ? (
        <Dialog
          open={Boolean(selectedRow)}
          onOpenChange={open => {
            if (!open) setSelectedRow(null)
          }}>
          <DialogContent
            className="flex max-h-[85vh] flex-col gap-4 overflow-hidden sm:max-w-3xl"
            closeLabel={t('common.close', { defaultValue: 'Close' })}>
            <DialogHeader>
              <DialogTitle>{t(`${i18nPrefix}.ui.details`, { defaultValue: 'Details' })}</DialogTitle>
            </DialogHeader>
            <div className="min-h-0 flex-1 overflow-y-auto pr-1">
              {detailSurface ? (
                <DeclarativePanelView
                  i18nPrefix={i18nPrefix}
                  recordId={
                    typeof selectedRow.id === 'string'
                      ? selectedRow.id
                      : typeof selectedRow.request_id === 'string'
                        ? selectedRow.request_id
                        : undefined
                  }
                  surface={detailSurface}
                />
              ) : (
                <DeclarativeFacts i18nPrefix={i18nPrefix} record={selectedRow} />
              )}
            </div>
          </DialogContent>
        </Dialog>
      ) : null}

      {activeRowModal ? (
        <DeclarativeActionTrigger
          i18nPrefix={i18nPrefix}
          payload={activeRowModal.payload}
          startOpen
          surface={activeRowModal.action}
          onDismiss={() => setActiveRowModal(null)}
          onExecute={runExecute}
        />
      ) : null}
    </div>
  )
}

export function resolveRouteTabSelection(
  tabs: readonly NonNullable<DeclarativeRouteSpec['tabs']>[number][],
  surfaceById: ReadonlyMap<string, DeclarativeSurfaceDescriptor>,
  isVisible: (surfaceId: string, fullSurface?: string) => boolean,
  requestedTab: string | null
) {
  const visibleTabs = tabs.filter(tab => {
    const target = surfaceById.get(tab.surfaceId)
    return Boolean(target && isVisible(target.id, target.surface))
  })
  const activeTabId =
    requestedTab && visibleTabs.some(tab => tab.id === requestedTab) ? requestedTab : (visibleTabs[0]?.id ?? '')
  return { visibleTabs, activeTabId }
}

export function DeclarativeRoutedPage({
  manifest,
  route
}: {
  manifest: DeclarativeConsoleManifest
  route: DeclarativeRouteSpec
}) {
  const { t } = useTranslation()
  const [searchParams, setSearchParams] = useSearchParams()
  const navigate = useNavigate()
  const params = useParams({ strict: false }) as Record<string, string | undefined>
  const visibility = useDeclarativeVisibility(manifest.visibilityEndpoint)
  const i18nPrefix = manifest.i18nPrefix ?? `${manifest.id}.console`
  const surfaceById = new Map(manifest.surfaces.map(surface => [surface.id, surface]))
  const surface = surfaceById.get(route.surfaceId)

  if (!surface) {
    return (
      <PageStack>
        <ErrorBlock error={new Error(`Missing surface descriptor "${route.surfaceId}"`)} />
      </PageStack>
    )
  }

  if (visibility.loading) {
    return (
      <PageStack>
        <p className="text-sm text-muted-foreground" role="status">
          {t('common.loading', { defaultValue: 'Loading...' })}
        </p>
      </PageStack>
    )
  }

  if (visibility.error) {
    return (
      <PageStack>
        <ErrorBlock error={visibility.error} />
      </PageStack>
    )
  }

  if (route.tabs && route.tabs.length > 0) {
    const { visibleTabs, activeTabId } = resolveRouteTabSelection(
      route.tabs,
      surfaceById,
      visibility.isVisible,
      searchParams.get('tab')
    )
    if (visibleTabs.length === 0) {
      return (
        <PageStack>
          <ErrorBlock error={t(`${i18nPrefix}.ui.unauthorized`, { defaultValue: 'Unauthorized' })} />
        </PageStack>
      )
    }
    const pageTitle = t(route.titleKey ?? surface.titleKey, { defaultValue: formatIdentifierLabel(route.id) })

    return (
      <PageStack>
        <PageHeader title={pageTitle} />
        <Tabs
          value={activeTabId}
          onValueChange={nextTab => {
            const nextParams = new URLSearchParams(searchParams)
            nextParams.set('tab', String(nextTab))
            setSearchParams(nextParams)
          }}>
          <TabsList>
            {visibleTabs.map(tab => (
              <TabsTrigger key={tab.id} value={tab.id}>
                {t(tab.labelKey, { defaultValue: formatIdentifierLabel(tab.id) })}
              </TabsTrigger>
            ))}
          </TabsList>
          {visibleTabs.map(tab => {
            const tabSurface = surfaceById.get(tab.surfaceId)
            if (!tabSurface) return null
            return (
              <TabsContent key={tab.id} className="pt-4" value={tab.id}>
                <DeclarativeSurfaceRouteBody
                  i18nPrefix={i18nPrefix}
                  route={route}
                  searchParams={searchParams}
                  setSearchParams={setSearchParams}
                  surface={tabSurface}
                  surfaceById={surfaceById}
                  visibleIds={visibility.ids}
                  onRefreshVisibility={visibility.refresh}
                  onNavigate={to => void navigate({ to })}
                  recordId={route.paramName ? params[route.paramName] : undefined}
                />
              </TabsContent>
            )
          })}
        </Tabs>
      </PageStack>
    )
  }

  if (!visibility.isVisible(surface.id, surface.surface)) {
    return (
      <PageStack>
        <ErrorBlock error={t(`${i18nPrefix}.ui.unauthorized`, { defaultValue: 'Unauthorized' })} />
      </PageStack>
    )
  }

  return (
    <DeclarativeSurfaceRouteBody
      i18nPrefix={i18nPrefix}
      recordId={route.paramName ? params[route.paramName] : undefined}
      route={route}
      searchParams={searchParams}
      setSearchParams={setSearchParams}
      surface={surface}
      surfaceById={surfaceById}
      visibleIds={visibility.ids}
      onNavigate={to => void navigate({ to })}
      onRefreshVisibility={visibility.refresh}
    />
  )
}

function DeclarativeSurfaceRouteBody({
  surface,
  route,
  surfaceById,
  visibleIds,
  i18nPrefix,
  searchParams,
  recordId,
  setSearchParams,
  onNavigate,
  onRefreshVisibility
}: {
  surface: DeclarativeSurfaceDescriptor
  route: DeclarativeRouteSpec
  surfaceById: ReadonlyMap<string, DeclarativeSurfaceDescriptor>
  visibleIds: ReadonlySet<string>
  i18nPrefix: string
  searchParams: URLSearchParams
  recordId?: string
  setSearchParams: (next: URLSearchParams) => void
  onNavigate: (to: string) => void
  onRefreshVisibility: () => void
}) {
  const filters: Record<string, string> = {}
  for (const key of new Set([...surface.filters, ...(surface.filterSchemas?.map(item => item.name) ?? [])])) {
    const val = searchParams.get(key)
    if (val) filters[key] = val
  }

  const endpoint =
    surface.kind === 'resource' || surface.presentation === 'table'
      ? surfaceQueryEndpoint(surface, recordId, filters)
      : undefined
  const query = useDeclarativeRecords(endpoint, 0, surface.responseEnvelope ?? 'jsonapi')

  if (route.mode === 'create' || route.mode === 'edit') {
    return (
      <DeclarativeResourceEditorView
        backPath={route.backPath ?? '/'}
        detailSurfaceId={route.detailSurfaceId ?? surface.detailSurfaceId ?? undefined}
        i18nPrefix={i18nPrefix}
        mode={route.mode}
        recordId={recordId}
        surface={surface}
        surfaceById={surfaceById}
        visibleIds={visibleIds}
        onNavigate={onNavigate}
      />
    )
  }

  if (surface.kind === 'dashboard') {
    return (
      <DeclarativeDashboardView
        i18nPrefix={i18nPrefix}
        schema={surface.dashboardSchema}
        surface={surface}
        onRefreshVisibility={onRefreshVisibility}
      />
    )
  }

  if ((surface.kind === 'panel' && surface.presentation !== 'table') || surface.presentation === 'form') {
    return <DeclarativePanelView i18nPrefix={i18nPrefix} recordId={recordId} surface={surface} />
  }

  return (
    <DeclarativeResourceTable
      detailSurfaceId={route.detailSurfaceId ?? surface.detailSurfaceId ?? undefined}
      error={query.error}
      filters={filters}
      i18nPrefix={i18nPrefix}
      loading={query.loading}
      rows={query.rows}
      surface={surface}
      surfaceById={surfaceById}
      titleOverride={route.tabs ? undefined : undefined}
      visibleIds={visibleIds}
      onChangeFilter={(name, val) => {
        const next = new URLSearchParams(searchParams)
        if (val) next.set(name, val)
        else next.delete(name)
        setSearchParams(next)
      }}
      onClearFilters={() => {
        const next = new URLSearchParams(searchParams)
        for (const key of Object.keys(filters)) next.delete(key)
        setSearchParams(next)
      }}
      onRefresh={query.refresh}
    />
  )
}

function DeclarativeResourceEditorView({
  surface,
  surfaceById,
  visibleIds,
  mode,
  recordId,
  detailSurfaceId,
  backPath,
  i18nPrefix,
  onNavigate
}: {
  surface: DeclarativeSurfaceDescriptor
  surfaceById: ReadonlyMap<string, DeclarativeSurfaceDescriptor>
  visibleIds: ReadonlySet<string>
  mode: 'create' | 'edit'
  recordId?: string
  detailSurfaceId?: string
  backPath: string
  i18nPrefix: string
  onNavigate: (to: string) => void
}) {
  const { t } = useTranslation()
  const readEndpoint = mode === 'edit' && recordId ? resolveRecordEndpoint(surface.endpoint, recordId) : undefined
  const recordQuery = useDeclarativeRecords(readEndpoint, 0, surface.responseEnvelope ?? 'jsonapi')
  const [draft, setDraft] = useState<Record<string, unknown>>({})
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState<unknown>(null)

  const record = recordQuery.rows[0]
  if (mode === 'edit' && recordQuery.loading) {
    return (
      <PageStack>
        <p className="text-sm text-muted-foreground" role="status">
          {t('common.loading', { defaultValue: 'Loading...' })}
        </p>
      </PageStack>
    )
  }

  if (mode === 'edit' && (recordQuery.error || !record)) {
    return (
      <EditorNotFound
        backTo={backPath}
        message={recordQuery.error ?? t('console.not_found.title', { defaultValue: 'Record not found' })}
      />
    )
  }

  const editableFields = surface.fields.filter(field => mode !== 'edit' || field.name !== 'id')
  const initialValues = Object.fromEntries(
    editableFields
      .filter(field => !field.readOnly && field.type !== 'secret' && record && field.name in record)
      .map(field => [field.name, record?.[field.name]])
  )
  const mergedDraft = { ...initialValues, ...draft }
  const resolvedDetailSurfaceId = detailSurfaceId ?? surface.detailSurfaceId
  const detailSurface = resolvedDetailSurfaceId ? surfaceById.get(resolvedDetailSurfaceId) : undefined

  const secondaryActions =
    mode === 'edit' && recordId
      ? Array.from(surfaceById.values()).filter(
          item =>
            item.id !== surface.id &&
            item.subject === surface.subject &&
            item.kind === 'action' &&
            item.endpoint.includes(':id') &&
            visibleIds.has(item.surface)
        )
      : []

  return (
    <ResourceEditorPage
      backTo={backPath}
      description={
        surface.titleKey ? t(`${i18nPrefix}.editor.description`, { defaultValue: '' }) || undefined : undefined
      }
      dirty={Object.keys(draft).length > 0}
      error={saveError}
      secondary={
        secondaryActions.length > 0 ? (
          <div className="flex flex-wrap gap-2">
            {secondaryActions.map(actionSurface => (
              <DeclarativeActionTrigger
                key={actionSurface.id}
                i18nPrefix={i18nPrefix}
                payload={record ? buildRowPrefillPayload(actionSurface, record) : { id: recordId }}
                surface={actionSurface}
                onExecute={async (target, payload) => {
                  const res = await executeDeclarativeAction(target, payload)
                  if (target.method === 'DELETE') {
                    onNavigate(backPath)
                  } else {
                    recordQuery.refresh()
                  }
                  return res
                }}
              />
            ))}
          </div>
        ) : undefined
      }
      submitting={saving}
      supplementary={
        mode === 'edit' && recordId && detailSurface && visibleIds.has(detailSurface.surface) ? (
          <DeclarativePanelView i18nPrefix={i18nPrefix} recordId={recordId} surface={detailSurface} />
        ) : undefined
      }
      title={
        mode === 'edit' && record && typeof record.name === 'string'
          ? record.name
          : t(surface.titleKey, { defaultValue: formatIdentifierLabel(surface.id) })
      }
      onSubmit={() => {
        setSaving(true)
        setSaveError(null)
        void executeDeclarativeAction(surface, serializeDeclarativeFields(surface, mergedDraft, recordId))
          .then(() => {
            setDraft({})
            toast.success(t('common.saved', { defaultValue: 'Saved' }))
            if (mode === 'edit') {
              recordQuery.refresh()
            } else {
              onNavigate(backPath)
            }
          })
          .catch((failure: unknown) => setSaveError(failure))
          .finally(() => setSaving(false))
      }}>
      <DeclarativeFields
        draft={mergedDraft}
        fields={editableFields}
        i18nPrefix={i18nPrefix}
        ruleSchema={surface.ruleSchema}
        onChange={next =>
          setDraft(
            Object.fromEntries(
              Object.entries(next).filter(([key, val]) => (!isRecord(val) ? val !== initialValues[key] : true))
            )
          )
        }
      />
    </ResourceEditorPage>
  )
}
