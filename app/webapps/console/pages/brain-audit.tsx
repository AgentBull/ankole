import {
  Button,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  Checkbox,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Input,
  Skeleton,
  cn,
  toast
} from '@ankole/uikit'
import { RiArrowGoBackLine, RiSparkling2Line } from '@remixicon/react'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useNavigate, useParams, useSearchParams } from 'react-router'
import {
  ankoleWebBrainControllerAuditIndexOptions,
  ankoleWebBrainControllerAuditLogOptions,
  ankoleWebBrainControllerDreamingFitnessOptions,
  ankoleWebBrainControllerRestoreAuditMutation,
  ankoleWebBrainControllerRestoreAuditsMutation,
  ankoleWebBrainControllerRunDreamingMutation,
  ankoleWebPrincipalControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { BrainDreamingFitnessRun } from '../api/generated/types.gen'
import { BackLink, PageHeader, PageStack, RefreshButton } from '../console-page'
import { ErrorBlock } from '../../common/error-block'
import { formatConsoleDate } from '../console-primitives'
import { LabeledField, StatusIndicator } from '../console-form'
import { CursorPagination } from '../console-list-page'
import {
  AuditTrail,
  type ActiveFilter,
  BrainOwnerField,
  BrainStoreField,
  BrainTaskNavigation,
  FilterDisclosure,
  RESTORABLE_AUDIT_ACTIONS,
  brainSearch,
  localDateStartISO,
  restorationAction
} from './brain-shared'
import {
  cursorPageNumber,
  hasPreviousCursor,
  nextCursorParams,
  previousCursorParams,
  resetCursorParams
} from '../state/cursor-pagination'
import {
  agentOwnerUID,
  brainAuditSelectionAfterRestore,
  brainAuditSelectionForScope,
  brainAuditSelectionScope,
  defaultBrainOwnerUID,
  setBrainFilter,
  type BrainAuditSelection
} from '../state/brain-editor-model'

export function BrainAuditPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const ownerUID = searchParams.get('owner') ?? defaultBrainOwnerUID(principals.data?.principals ?? [])
  const store = searchParams.get('store') ?? ''
  const action = searchParams.get('action') ?? ''
  const actor = searchParams.get('actor') ?? ''
  const runID = searchParams.get('run') ?? ''
  const insertedAfter = searchParams.get('after') ?? ''
  const insertedBefore = searchParams.get('before') ?? ''
  const cursor = searchParams.get('cursor') ?? ''
  const selectionScope = brainAuditSelectionScope(ownerUID, searchParams)
  const [selection, setSelection] = useState<BrainAuditSelection>(() => ({
    scope: selectionScope,
    ids: new Set(),
    confirming: false
  }))
  const activeSelection = brainAuditSelectionForScope(selection, selectionScope)
  if (activeSelection !== selection) setSelection(activeSelection)
  const selectedIDs = activeSelection.ids
  const audit = useQuery({
    ...ankoleWebBrainControllerAuditIndexOptions({
      query: {
        owner_uid: ownerUID,
        store: store || undefined,
        action: action || undefined,
        actor: actor || undefined,
        run_id: runID || undefined,
        inserted_after: localDateStartISO(insertedAfter),
        inserted_before: localDateEndISO(insertedBefore),
        cursor: cursor || undefined,
        limit: 50
      }
    }),
    enabled: Boolean(ownerUID)
  })
  const restore = useMutation({
    ...ankoleWebBrainControllerRestoreAuditsMutation(),
    onMutate: variables => ({ selection: activeSelection, count: variables.body.audit_ids.length }),
    onSuccess: (_data, _variables, submitted) => {
      if (!submitted) return
      toast.success(t('console.brain.batch_restored', { count: submitted.count }))
      setSelection(current => brainAuditSelectionAfterRestore(current, submitted.selection))
      void queryClient.invalidateQueries()
    }
  })
  const rows = audit.data?.audit_log ?? []
  const restorableRows = rows.filter(row => RESTORABLE_AUDIT_ACTIONS.has(row.action))
  const allPageSelected = restorableRows.length > 0 && restorableRows.every(row => selectedIDs.has(row.id))

  const restoreSelected = () => {
    const auditIDs = [...selectedIDs]
    if (!ownerUID || auditIDs.length === 0) return

    restore.mutate({
      query: { owner_uid: ownerUID },
      body: { audit_ids: auditIDs }
    })
  }

  useEffect(() => {
    if (searchParams.has('owner') || !ownerUID) return
    const next = new URLSearchParams(searchParams)
    next.set('owner', ownerUID)
    setSearchParams(next, { replace: true })
  }, [ownerUID, searchParams, setSearchParams])

  const setFilter = (key: string, value: string) => {
    setSearchParams(setBrainFilter(searchParams, key, value), { replace: true })
  }

  const clearFilters = () => {
    const next = new URLSearchParams(searchParams)
    for (const key of ['store', 'action', 'actor', 'run', 'after', 'before']) next.delete(key)
    setSearchParams(resetCursorParams(next), { replace: true })
  }

  const anyFilterActive = Boolean(store || action || actor || runID || insertedAfter || insertedBefore)
  // Only the filters the disclosure hides: its badge counts what the collapsed
  // panel holds, and its chips restate values no visible input already shows.
  const activeAdvancedFilters: ActiveFilter[] = []
  if (store) {
    activeAdvancedFilters.push({
      id: 'store',
      label: t('console.brain.store'),
      value:
        store === 'shared' ? t('console.brain.store_shared') : store === 'self' ? t('console.brain.store_self') : store,
      onRemove: () => setFilter('store', '')
    })
  }
  if (runID) {
    activeAdvancedFilters.push({
      id: 'run',
      label: t('console.brain.audit_run'),
      value: runID,
      onRemove: () => setFilter('run', '')
    })
  }

  const toggleRow = (id: string, selected: boolean) => {
    setSelection(current => {
      const active = brainAuditSelectionForScope(current, selectionScope)
      const next = new Set(active.ids)
      if (selected) next.add(id)
      else next.delete(id)
      return { ...active, ids: next }
    })
  }

  const togglePage = (selected: boolean) => {
    setSelection(current => {
      const active = brainAuditSelectionForScope(current, selectionScope)
      const next = new Set(active.ids)
      for (const row of restorableRows) {
        if (selected) next.add(row.id)
        else next.delete(row.id)
      }
      return { ...active, ids: next }
    })
  }

  return (
    <PageStack>
      <PageHeader
        title={t('console.brain.audit_title')}
        description={t('console.brain.audit_description')}
        actions={
          <>
            <RefreshButton />
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={selectedIDs.size === 0 || restore.isPending}
              onClick={() =>
                setSelection(current => ({
                  ...brainAuditSelectionForScope(current, selectionScope),
                  confirming: true
                }))
              }>
              <RiArrowGoBackLine />
              {t('console.brain.restore_selected', { count: selectedIDs.size })}
            </Button>
          </>
        }
      />
      <BrainTaskNavigation ownerUID={ownerUID} store={store || undefined} />

      <div className="grid gap-4 border border-border bg-card p-4">
        <BrainOwnerField
          ownerUID={ownerUID}
          principals={principals.data?.principals ?? []}
          onChange={value => setFilter('owner', value)}
        />
        <div className="grid gap-3 border-t border-border pt-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h3 className="text-sm font-medium">{t('console.brain.filters')}</h3>
            {/* The button clears every filter, so it has to appear for every
                filter — the visible fields included, not only the two the
                disclosure hides. */}
            {anyFilterActive ? (
              <Button type="button" size="xs" variant="ghost" onClick={clearFilters}>
                {t('console.brain.clear_filters')}
              </Button>
            ) : null}
          </div>
          <div className="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-4">
            <LabeledField label={t('console.brain.audit_action')}>
              <Input
                list="brain-audit-actions"
                value={action}
                onChange={event => setFilter('action', event.target.value)}
              />
              <datalist id="brain-audit-actions">
                {[...RESTORABLE_AUDIT_ACTIONS].map(value => (
                  <option key={value} value={value} />
                ))}
              </datalist>
            </LabeledField>
            <LabeledField label={t('console.brain.audit_actor')}>
              <Input
                value={actor}
                placeholder={t('console.brain.audit_actor_placeholder')}
                onChange={event => setFilter('actor', event.target.value)}
              />
            </LabeledField>
            <LabeledField label={t('console.brain.audit_after')}>
              <Input type="date" value={insertedAfter} onChange={event => setFilter('after', event.target.value)} />
            </LabeledField>
            <LabeledField label={t('console.brain.audit_before')}>
              <Input type="date" value={insertedBefore} onChange={event => setFilter('before', event.target.value)} />
            </LabeledField>
          </div>
          <FilterDisclosure filters={activeAdvancedFilters}>
            <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
              <BrainStoreField
                ownerUID={ownerUID}
                store={store}
                principals={principals.data?.principals ?? []}
                allowAll
                onChange={value => setFilter('store', value)}
              />
              <LabeledField label={t('console.brain.audit_run')}>
                <Input
                  value={runID}
                  placeholder={t('console.brain.audit_run_placeholder')}
                  onChange={event => setFilter('run', event.target.value)}
                />
              </LabeledField>
            </div>
          </FilterDisclosure>
        </div>
      </div>

      {restorableRows.length > 0 ? (
        <div className="flex justify-end">
          <label className="flex items-end gap-3 pb-2 text-sm">
            <Checkbox checked={allPageSelected} onCheckedChange={checked => togglePage(checked === true)} />
            <span>{t('console.brain.select_page')}</span>
          </label>
        </div>
      ) : null}
      <AuditTrail
        rows={rows}
        loading={audit.isLoading || principals.isLoading}
        error={audit.error ?? principals.error}
        restoring={restore.isPending}
        selectedIDs={selectedIDs}
        onSelectedChange={toggleRow}
        entryHref={row =>
          row.entry_id
            ? `/brain/${row.action === 'delete_entry' ? `audit/${row.entry_id}` : row.entry_id}?${brainSearch(ownerUID, row.store_key)}`
            : undefined
        }
      />
      {rows.length > 0 || hasPreviousCursor(searchParams) ? (
        <CursorPagination
          page={cursorPageNumber(searchParams)}
          hasPrevious={hasPreviousCursor(searchParams)}
          nextCursor={audit.data?.next_cursor}
          resultCount={rows.length}
          onPrevious={() => setSearchParams(previousCursorParams(searchParams))}
          onNext={nextCursor => setSearchParams(nextCursorParams(searchParams, nextCursor))}
        />
      ) : null}

      <Dialog
        open={activeSelection.confirming && selectedIDs.size > 0}
        onOpenChange={open => {
          if (restore.isPending) return
          setSelection(current => ({
            ...brainAuditSelectionForScope(current, selectionScope),
            confirming: open
          }))
        }}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!restore.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.brain.restore_selected_title')}</DialogTitle>
            <DialogDescription>
              {t('console.brain.restore_selected_description', { count: selectedIDs.size })}
            </DialogDescription>
          </DialogHeader>
          <ErrorBlock error={restore.error} />
          <DialogFooter>
            <DialogClose render={<Button variant="outline" disabled={restore.isPending} />}>
              {t('common.cancel')}
            </DialogClose>
            <Button disabled={!ownerUID || selectedIDs.size === 0 || restore.isPending} onClick={restoreSelected}>
              {t('console.brain.restore_selected', { count: selectedIDs.size })}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </PageStack>
  )
}

export function BrainDreamingPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const agents = (principals.data?.principals ?? []).filter(principal => principal.type === 'agent')
  const ownerUID = agentOwnerUID(searchParams.get('owner'), agents)
  const runDreaming = useMutation({
    ...ankoleWebBrainControllerRunDreamingMutation(),
    onSuccess: data => {
      toast.success(
        t('console.brain.dreaming_finished', { status: t(`console.brain.dreaming_status_${data.run.status}`) })
      )
      void queryClient.invalidateQueries()
    }
  })

  useEffect(() => {
    if (searchParams.get('owner') === ownerUID || !ownerUID) return
    const next = new URLSearchParams(searchParams)
    next.set('owner', ownerUID)
    setSearchParams(next, { replace: true })
  }, [ownerUID, searchParams, setSearchParams])

  const run = runDreaming.data?.run

  return (
    <PageStack>
      <PageHeader
        title={t('console.brain.dreaming_title')}
        description={t('console.brain.dreaming_description')}
        actions={
          <>
            <RefreshButton />
            <Button
              type="button"
              size="sm"
              disabled={!ownerUID || runDreaming.isPending}
              onClick={() => runDreaming.mutate({ query: { owner_uid: ownerUID } })}>
              <RiSparkling2Line />
              {runDreaming.isPending ? t('console.brain.dreaming_running') : t('console.brain.run_dreaming')}
            </Button>
          </>
        }
      />
      <BrainTaskNavigation ownerUID={ownerUID} />

      <div className="grid grid-cols-1 gap-4 border border-border bg-card p-4 md:grid-cols-2">
        <BrainOwnerField
          ownerUID={ownerUID}
          principals={agents}
          onChange={value => setSearchParams(setBrainFilter(searchParams, 'owner', value), { replace: true })}
        />
        <div className="self-end text-sm leading-6 text-muted-foreground">
          {t('console.brain.dreaming_owner_description')}
        </div>
      </div>

      <ErrorBlock error={principals.error ?? runDreaming.error} />
      {run ? (
        <Card>
          <CardHeader>
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div className="grid gap-1">
                <CardTitle>{t('console.brain.dreaming_result_title')}</CardTitle>
                <CardDescription className="break-all font-mono text-xs">{run.run_id || '—'}</CardDescription>
              </div>
              <StatusIndicator tone={dreamingStatusTone(run.status)}>
                {t(`console.brain.dreaming_status_${run.status}`)}
              </StatusIndicator>
            </div>
          </CardHeader>
          <CardContent className="grid grid-cols-1 gap-3 sm:grid-cols-3">
            <FitnessStat label={t('console.brain.dreaming_materials')} value={String(run.material_count ?? 0)} />
            <FitnessStat label={t('console.brain.dreaming_operations')} value={String(run.operation_count ?? 0)} />
            <FitnessStat
              label={t('console.brain.dreaming_skill_updates')}
              value={String(run.skill_update_count ?? 0)}
            />
          </CardContent>
        </Card>
      ) : null}

      <DreamingFitnessCard
        ownerUID={ownerUID}
        onSelectRun={runID => {
          const next = new URLSearchParams()
          if (ownerUID) next.set('owner', ownerUID)
          next.set('run', runID)
          navigate(`/brain/audit?${next.toString()}`)
        }}
      />
    </PageStack>
  )
}

export function BrainEntryAuditPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const params = useParams()
  const [searchParams, setSearchParams] = useSearchParams()
  const entryID = params.id ?? ''
  const ownerUID = searchParams.get('owner') ?? ''
  const store = searchParams.get('store') ?? undefined
  const auditCursor = searchParams.get('audit_cursor') ?? ''
  const audit = useQuery({
    ...ankoleWebBrainControllerAuditLogOptions({
      path: { id: entryID },
      query: { owner_uid: ownerUID, cursor: auditCursor || undefined, limit: 50 }
    }),
    enabled: Boolean(entryID && ownerUID),
    retry: false
  })
  const restore = useMutation({
    ...ankoleWebBrainControllerRestoreAuditMutation(),
    onSuccess: data => {
      toast.success(t('console.brain.restored'))
      void queryClient.invalidateQueries()
      if (restorationAction(data.restoration) === 'delete_entry') {
        navigate(`/brain/${entryID}?${brainSearch(ownerUID, store)}`)
      }
    }
  })

  return (
    <PageStack className="mx-auto max-w-3xl">
      <BackLink to={`/brain?${brainSearch(ownerUID, store)}`} />
      <BrainTaskNavigation ownerUID={ownerUID} store={store} />
      <div>
        <h2 className="text-2xl font-semibold">{t('console.brain.deleted_audit_title')}</h2>
        <p className="break-all font-mono text-xs text-muted-foreground">{entryID}</p>
      </div>
      <p className="text-sm text-muted-foreground">{t('console.brain.deleted_audit_description')}</p>
      {/* A failed restore reports beside the list. Inside AuditTrail it would
          replace the rows, taking away the entries the operator can still restore. */}
      <ErrorBlock error={restore.error} />
      <AuditTrail
        rows={audit.data?.audit_log ?? []}
        loading={audit.isLoading}
        error={audit.error}
        restoring={restore.isPending}
        onRestore={auditID => restore.mutate({ path: { audit_id: auditID }, query: { owner_uid: ownerUID } })}
      />
      {(audit.data?.audit_log.length ?? 0) > 0 || hasPreviousCursor(searchParams, 'audit_') ? (
        <CursorPagination
          page={cursorPageNumber(searchParams, 'audit_')}
          hasPrevious={hasPreviousCursor(searchParams, 'audit_')}
          nextCursor={audit.data?.next_cursor}
          resultCount={audit.data?.audit_log.length ?? 0}
          onPrevious={() => setSearchParams(previousCursorParams(searchParams, 'audit_'))}
          onNext={nextCursor => setSearchParams(nextCursorParams(searchParams, nextCursor, 'audit_'))}
        />
      ) : null}
    </PageStack>
  )
}

function dreamingStatusTone(status: string): 'neutral' | 'positive' | 'warning' {
  if (status === 'completed') return 'positive'
  if (status === 'already_running') return 'warning'
  return 'neutral'
}

function DreamingFitnessCard({ ownerUID, onSelectRun }: { ownerUID: string; onSelectRun: (runID: string) => void }) {
  const { t } = useTranslation()
  // The field shows the draft while only valid values reach the query, so a
  // cleared input cannot silently keep querying the previous horizon.
  const [horizonDraft, setHorizonDraft] = useState('7')
  const [horizonDays, setHorizonDays] = useState(7)
  const fitness = useQuery({
    ...ankoleWebBrainControllerDreamingFitnessOptions({
      query: { owner_uid: ownerUID, horizon_days: horizonDays }
    }),
    enabled: Boolean(ownerUID)
  })
  const data = fitness.data?.fitness

  return (
    <Card>
      <CardHeader>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="grid gap-1">
            <CardTitle className="flex items-center gap-2">
              <RiSparkling2Line />
              {t('console.brain.fitness_title')}
            </CardTitle>
            <CardDescription className="max-w-3xl">{t('console.brain.fitness_description')}</CardDescription>
          </div>
          <LabeledField label={t('console.brain.fitness_horizon')}>
            <Input
              type="number"
              min={1}
              max={90}
              className="w-28"
              value={horizonDraft}
              onChange={event => {
                setHorizonDraft(event.target.value)
                const next = Number.parseInt(event.target.value, 10)
                if (Number.isFinite(next) && next >= 1 && next <= 90) setHorizonDays(next)
              }}
              // The metrics keep the last applied horizon while the operator
              // retypes; on blur an abandoned invalid draft snaps back to it,
              // so the field never disagrees with the data at rest.
              onBlur={() => setHorizonDraft(String(horizonDays))}
            />
          </LabeledField>
        </div>
      </CardHeader>
      <CardContent className="grid gap-4">
        <ErrorBlock error={fitness.error} />
        {fitness.isLoading ? (
          <Skeleton className="h-24 w-full" />
        ) : data ? (
          <>
            <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
              <FitnessStat
                label={t('console.brain.fitness_survival_rate')}
                value={formatPercent(data.survival_rate)}
                emphasis
              />
              <FitnessStat label={t('console.brain.fitness_matured')} value={String(data.matured_block_writes)} />
              <FitnessStat label={t('console.brain.fitness_corrected')} value={String(data.corrected_block_writes)} />
              <FitnessStat label={t('console.brain.fitness_pending')} value={String(data.pending_block_writes)} />
            </div>
            {data.matured_block_writes === 0 ? (
              <p className="text-sm text-muted-foreground">{t('console.brain.fitness_no_data')}</p>
            ) : (
              <div className="overflow-x-auto border border-border">
                <div className="grid min-w-[720px] gap-px bg-border">
                  <div className="grid grid-cols-[2fr_repeat(4,1fr)] gap-3 bg-muted px-3 py-2 text-xs font-medium text-muted-foreground">
                    <span>{t('console.brain.fitness_run')}</span>
                    <span className="text-right">{t('console.brain.fitness_survived')}</span>
                    <span className="text-right">{t('console.brain.fitness_corrected')}</span>
                    <span className="text-right">{t('console.brain.fitness_survival_rate')}</span>
                    <span className="text-right">{t('console.brain.fitness_last_written')}</span>
                  </div>
                  {data.runs.map(run => (
                    <FitnessRunRow key={run.run_id ?? 'unattributed'} run={run} onSelectRun={onSelectRun} />
                  ))}
                </div>
              </div>
            )}
          </>
        ) : null}
      </CardContent>
    </Card>
  )
}

function FitnessStat({ label, value, emphasis }: { label: string; value: string; emphasis?: boolean }) {
  return (
    <div className="grid gap-1 border border-border bg-card p-3">
      <span className="text-xs text-muted-foreground">{label}</span>
      <span className={cn('font-semibold', emphasis ? 'text-2xl' : 'text-lg')}>{value}</span>
    </div>
  )
}

function FitnessRunRow({ run, onSelectRun }: { run: BrainDreamingFitnessRun; onSelectRun: (runID: string) => void }) {
  const { t } = useTranslation()
  return (
    <div className="grid grid-cols-[2fr_repeat(4,1fr)] items-center gap-3 bg-card px-3 py-2 text-sm">
      {run.run_id ? (
        <button
          type="button"
          className="truncate text-left font-mono text-xs text-link hover:underline"
          title={run.run_id}
          onClick={() => onSelectRun(run.run_id ?? '')}>
          {run.run_id}
        </button>
      ) : (
        <span className="truncate font-mono text-xs text-muted-foreground">
          {t('console.brain.fitness_unattributed')}
        </span>
      )}
      <span className="text-right tabular-nums">
        {run.survived_block_writes}/{run.matured_block_writes}
      </span>
      <span className="text-right tabular-nums">{run.corrected_block_writes}</span>
      <span className="text-right tabular-nums">{formatPercent(run.survival_rate)}</span>
      <span className="text-right text-xs text-muted-foreground">{formatConsoleDate(run.last_written_at)}</span>
    </div>
  )
}

function formatPercent(rate?: number | null): string {
  if (rate === null || rate === undefined) return '—'
  return `${(rate * 100).toFixed(1)}%`
}

function localDateEndISO(value: string): string | undefined {
  if (!value) return undefined
  const date = new Date(`${value}T00:00:00`)
  if (Number.isNaN(date.getTime())) return undefined
  date.setDate(date.getDate() + 1)
  date.setMilliseconds(date.getMilliseconds() - 1)
  return date.toISOString()
}
