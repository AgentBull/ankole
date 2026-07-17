import {
  Badge,
  Button,
  Checkbox,
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Input,
  Skeleton,
  TableCell,
  TableRow,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  Textarea,
  cn,
  toast
} from '@ankole/uikit'
import {
  RiArrowDownSLine,
  RiExternalLinkLine,
  RiFilter3Line,
  RiHistoryLine,
  RiRefreshLine,
  RiSparkling2Line
} from '@remixicon/react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { type ReactNode, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebBrainControllerApplyOperationsMutation,
  ankoleWebBrainControllerAuditIndexOptions,
  ankoleWebBrainControllerAuditLogOptions,
  ankoleWebBrainControllerDreamingFitnessOptions,
  ankoleWebBrainControllerIndexOptions,
  ankoleWebBrainControllerRestoreAuditMutation,
  ankoleWebBrainControllerRestoreAuditsMutation,
  ankoleWebBrainControllerRunDreamingMutation,
  ankoleWebBrainControllerShowOptions,
  ankoleWebPrincipalControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type {
  BrainAuditLog,
  BrainCitation,
  BrainDreamingFitnessRun,
  BrainEntryOperation
} from '../api/generated/types.gen'
import { ErrorBlock, formatJSON } from '../console-primitives'
import {
  ConfirmDeleteButton,
  LabeledField,
  PageHeader,
  ResourceEditorPage,
  ResourceListPage,
  RowActions,
  StatusIndicator
} from '../console-shell'
import { BlocksEditor, MetadataEditor, RelationsEditor } from './brain-entry-editors'
import {
  BrainOwnerField,
  BrainStoreField,
  BrainStoreName,
  BrainTaskNavigation,
  brainSearch,
  formatBrainDate
} from './brain-shared'
import {
  BrainMetadataEditorModel,
  brainCursorPage,
  buildMetadataOperations,
  canReturnBrainCursor,
  defaultBrainOwnerUID,
  nextBrainCursor,
  parsePropertyDrafts,
  previousBrainCursor,
  propertiesToDrafts,
  setBrainFilter
} from '../state/brain-editor-model'

const RESTORABLE_AUDIT_ACTIONS = new Set([
  'create_entry',
  'delete_entry',
  'append_block',
  'edit_block',
  'delete_block',
  'set_property',
  'set_summary',
  'set_aliases',
  'set_name',
  'set_type',
  'add_relation',
  'remove_relation'
])

export function BrainEntriesPage() {
  const { t } = useTranslation()
  const [searchParams, setSearchParams] = useSearchParams()
  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const ownerUID = searchParams.get('owner') ?? defaultBrainOwnerUID(principals.data?.principals ?? [])
  const entryType = searchParams.get('type') ?? ''
  const query = searchParams.get('q') ?? ''
  const store = searchParams.get('store') ?? ''
  const author = searchParams.get('author') ?? ''
  const updated = searchParams.get('updated') ?? ''
  const cursor = searchParams.get('cursor') ?? ''
  const advancedFilterCount = [entryType, store, author, updated].filter(Boolean).length
  const isFiltered = Boolean(query || advancedFilterCount)
  const list = useQuery({
    ...ankoleWebBrainControllerIndexOptions({
      query: {
        owner_uid: ownerUID,
        query: query || undefined,
        type: entryType || undefined,
        store: store || undefined,
        author: author || undefined,
        updated: localDateStartISO(updated),
        cursor: cursor || undefined,
        limit: 50
      }
    }),
    enabled: Boolean(ownerUID)
  })
  const guide = useQuery({
    ...ankoleWebBrainControllerIndexOptions({
      query: { owner_uid: ownerUID, store: 'public', type: 'brain_curation_guide', limit: 1 }
    }),
    enabled: Boolean(ownerUID)
  })
  const entries = list.data?.entries ?? []
  const guideEntry = guide.data?.entries[0]

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
    const next = new URLSearchParams()
    if (ownerUID) next.set('owner', ownerUID)
    setSearchParams(next, { replace: true })
  }

  const clearAdvancedFilters = () => {
    const next = new URLSearchParams(searchParams)
    for (const key of ['type', 'store', 'author', 'updated', 'cursor']) next.delete(key)
    setSearchParams(next, { replace: true })
  }

  return (
    <ResourceListPage
      title={t('console.brain.title')}
      description={t('console.brain.description')}
      columns={[
        t('console.brain.name'),
        t('console.brain.type'),
        t('console.brain.store'),
        t('console.brain.summary'),
        t('console.brain.updated')
      ]}
      createLabel={t('console.brain.write_entry')}
      createTo={`new?${brainSearch(ownerUID, store || 'public')}`}
      isLoading={list.isLoading || principals.isLoading}
      isEmpty={entries.length === 0}
      emptyTitle={t('console.brain.empty_title')}
      emptyDescription={t('console.brain.empty_description')}
      emptyAction={
        isFiltered ? (
          <Button type="button" size="sm" variant="outline" onClick={clearFilters}>
            {t('console.brain.clear_filters')}
          </Button>
        ) : undefined
      }
      isFiltered={isFiltered}
      error={list.error ?? guide.error ?? principals.error}
      toolbar={
        <div className="grid gap-4">
          <BrainTaskNavigation active="entries" ownerUID={ownerUID} store={store || undefined} />
          <div className="flex flex-wrap items-center justify-between gap-3 border border-border bg-card p-4">
            <div className="grid gap-1">
              <h3 className="text-sm font-medium">{t('console.brain.guide_title')}</h3>
              <p className="text-sm text-muted-foreground">{t('console.brain.guide_description')}</p>
            </div>
            <Button
              render={
                <Link
                  to={
                    guideEntry
                      ? `/brain/${guideEntry.id}?${brainSearch(ownerUID, 'public')}`
                      : `/brain/new?${brainSearch(ownerUID, 'public')}&kind=curation-guide`
                  }
                />
              }
              size="sm"
              variant="outline">
              {guideEntry ? t('console.brain.guide_edit') : t('console.brain.guide_create')}
            </Button>
          </div>
          <div className="grid gap-4 border border-border bg-card p-4">
            <div className="grid gap-3 md:grid-cols-2">
              <LabeledField label={t('console.brain.search')}>
                <Input
                  type="search"
                  value={query}
                  placeholder={t('console.brain.search_placeholder')}
                  onChange={event => setFilter('q', event.target.value)}
                />
              </LabeledField>
              <BrainOwnerField
                ownerUID={ownerUID}
                principals={principals.data?.principals ?? []}
                onChange={value => setFilter('owner', value)}
              />
            </div>
            <FilterDisclosure count={advancedFilterCount} onClear={clearAdvancedFilters}>
              <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
                <LabeledField label={t('console.brain.type')}>
                  <Input value={entryType} onChange={event => setFilter('type', event.target.value)} />
                </LabeledField>
                <BrainStoreField
                  ownerUID={ownerUID}
                  store={store}
                  principals={principals.data?.principals ?? []}
                  allowAll
                  onChange={value => setFilter('store', value)}
                />
                <LabeledField label={t('console.brain.author')}>
                  <Input
                    value={author}
                    placeholder={t('console.brain.author_placeholder')}
                    onChange={event => setFilter('author', event.target.value)}
                  />
                </LabeledField>
                <LabeledField label={t('console.brain.updated_after')}>
                  <Input type="date" value={updated} onChange={event => setFilter('updated', event.target.value)} />
                </LabeledField>
              </div>
            </FilterDisclosure>
            <CursorPagination
              page={brainCursorPage(searchParams)}
              hasPrevious={canReturnBrainCursor(searchParams)}
              nextCursor={list.data?.next_cursor}
              resultCount={entries.length}
              onPrevious={() => setSearchParams(previousBrainCursor(searchParams))}
              onNext={nextCursor => setSearchParams(nextBrainCursor(searchParams, nextCursor))}
            />
          </div>
        </div>
      }>
      {entries.map(entry => (
        <TableRow key={entry.id}>
          <TableCell className="font-medium">
            <Link to={`${entry.id}?${brainSearch(ownerUID, entry.store_key)}`} className="text-primary hover:underline">
              {entry.name}
            </Link>
          </TableCell>
          <TableCell>
            <Badge variant="secondary">{entry.type}</Badge>
          </TableCell>
          <TableCell className="text-xs">
            <BrainStoreName store={entry.store_key} principals={principals.data?.principals ?? []} />
          </TableCell>
          <TableCell className="max-w-md truncate text-muted-foreground">{entry.summary || '—'}</TableCell>
          <TableCell className="whitespace-nowrap text-xs text-muted-foreground">
            {formatBrainDate(entry.updated_at)}
          </TableCell>
          <RowActions editLabel={t('common.edit')} editTo={`${entry.id}?${brainSearch(ownerUID, entry.store_key)}`} />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

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
  const [selectedIDs, setSelectedIDs] = useState<Set<string>>(() => new Set())
  const [confirmOpen, setConfirmOpen] = useState(false)
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
    onSuccess: () => {
      toast.success(t('console.brain.batch_restored', { count: selectedIDs.size }))
      setConfirmOpen(false)
      setSelectedIDs(new Set())
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const rows = audit.data?.audit_log ?? []
  const restorableRows = rows.filter(row => RESTORABLE_AUDIT_ACTIONS.has(row.action))
  const allPageSelected = restorableRows.length > 0 && restorableRows.every(row => selectedIDs.has(row.id))
  const advancedFilterCount = [store, action, actor, runID, insertedAfter, insertedBefore].filter(Boolean).length

  useEffect(() => {
    if (searchParams.has('owner') || !ownerUID) return
    const next = new URLSearchParams(searchParams)
    next.set('owner', ownerUID)
    setSearchParams(next, { replace: true })
  }, [ownerUID, searchParams, setSearchParams])

  const setFilter = (key: string, value: string) => {
    setSelectedIDs(new Set())
    setSearchParams(setBrainFilter(searchParams, key, value), { replace: true })
  }

  const clearAdvancedFilters = () => {
    setSelectedIDs(new Set())
    const next = new URLSearchParams(searchParams)
    for (const key of ['store', 'action', 'actor', 'run', 'after', 'before', 'cursor']) next.delete(key)
    setSearchParams(next, { replace: true })
  }

  const toggleRow = (id: string, selected: boolean) => {
    setSelectedIDs(current => {
      const next = new Set(current)
      if (selected) next.add(id)
      else next.delete(id)
      return next
    })
  }

  const togglePage = (selected: boolean) => {
    setSelectedIDs(current => {
      const next = new Set(current)
      for (const row of restorableRows) {
        if (selected) next.add(row.id)
        else next.delete(row.id)
      }
      return next
    })
  }

  return (
    <div className="grid gap-6">
      <PageHeader
        title={t('console.brain.audit_title')}
        description={t('console.brain.audit_description')}
        actions={
          <Button
            type="button"
            variant="outline"
            disabled={selectedIDs.size === 0 || restore.isPending}
            onClick={() => setConfirmOpen(true)}>
            <RiRefreshLine />
            {t('console.brain.restore_selected', { count: selectedIDs.size })}
          </Button>
        }
      />
      <BrainTaskNavigation active="audit" ownerUID={ownerUID} store={store || undefined} />

      <div className="grid gap-4 border border-border bg-card p-4">
        <BrainOwnerField
          ownerUID={ownerUID}
          principals={principals.data?.principals ?? []}
          onChange={value => setFilter('owner', value)}
        />
        <FilterDisclosure count={advancedFilterCount} onClear={clearAdvancedFilters}>
          <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
            <LabeledField label={t('console.brain.store')}>
              <Input value={store} placeholder="public" onChange={event => setFilter('store', event.target.value)} />
            </LabeledField>
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
            <LabeledField label={t('console.brain.audit_run')}>
              <Input
                value={runID}
                placeholder={t('console.brain.audit_run_placeholder')}
                onChange={event => setFilter('run', event.target.value)}
              />
            </LabeledField>
            <LabeledField label={t('console.brain.audit_after')}>
              <Input type="date" value={insertedAfter} onChange={event => setFilter('after', event.target.value)} />
            </LabeledField>
            <LabeledField label={t('console.brain.audit_before')}>
              <Input type="date" value={insertedBefore} onChange={event => setFilter('before', event.target.value)} />
            </LabeledField>
          </div>
        </FilterDisclosure>
        <div className="flex justify-end">
          <label className="flex items-end gap-3 pb-2 text-sm">
            <Checkbox checked={allPageSelected} onCheckedChange={checked => togglePage(checked === true)} />
            <span>{t('console.brain.select_page')}</span>
          </label>
        </div>
        <CursorPagination
          page={brainCursorPage(searchParams)}
          hasPrevious={canReturnBrainCursor(searchParams)}
          nextCursor={audit.data?.next_cursor}
          resultCount={rows.length}
          onPrevious={() => setSearchParams(previousBrainCursor(searchParams))}
          onNext={nextCursor => setSearchParams(nextBrainCursor(searchParams, nextCursor))}
        />
      </div>

      <ErrorBlock error={restore.error} />
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

      <Dialog open={confirmOpen} onOpenChange={setConfirmOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('console.brain.restore_selected_title')}</DialogTitle>
            <DialogDescription>
              {t('console.brain.restore_selected_description', { count: selectedIDs.size })}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />}>{t('common.cancel')}</DialogClose>
            <Button
              disabled={!ownerUID || selectedIDs.size === 0 || restore.isPending}
              onClick={() =>
                restore.mutate({
                  query: { owner_uid: ownerUID },
                  body: { audit_ids: [...selectedIDs] }
                })
              }>
              {t('console.brain.restore_selected', { count: selectedIDs.size })}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}

export function BrainDreamingPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const ownerUID = searchParams.get('owner') ?? defaultBrainOwnerUID(principals.data?.principals ?? [])
  const runDreaming = useMutation({
    ...ankoleWebBrainControllerRunDreamingMutation(),
    onSuccess: data =>
      toast.success(
        t('console.brain.dreaming_finished', { status: t(`console.brain.dreaming_status_${data.run.status}`) })
      ),
    onError: error => toast.error(requestErrorMessage(error))
  })

  useEffect(() => {
    if (searchParams.has('owner') || !ownerUID) return
    const next = new URLSearchParams(searchParams)
    next.set('owner', ownerUID)
    setSearchParams(next, { replace: true })
  }, [ownerUID, searchParams, setSearchParams])

  const run = runDreaming.data?.run

  return (
    <div className="grid gap-6">
      <PageHeader
        title={t('console.brain.dreaming_title')}
        description={t('console.brain.dreaming_description')}
        actions={
          <Button
            type="button"
            disabled={!ownerUID || runDreaming.isPending}
            onClick={() => runDreaming.mutate({ query: { owner_uid: ownerUID } })}>
            <RiSparkling2Line />
            {runDreaming.isPending ? t('console.brain.dreaming_running') : t('console.brain.run_dreaming')}
          </Button>
        }
      />
      <BrainTaskNavigation active="dreaming" ownerUID={ownerUID} />

      <div className="grid gap-4 border border-border bg-card p-4 md:grid-cols-2">
        <BrainOwnerField
          ownerUID={ownerUID}
          principals={principals.data?.principals ?? []}
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
          <CardContent className="grid gap-3 sm:grid-cols-2">
            <FitnessStat label={t('console.brain.dreaming_materials')} value={String(run.material_count ?? 0)} />
            <FitnessStat label={t('console.brain.dreaming_operations')} value={String(run.operation_count ?? 0)} />
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
    </div>
  )
}

export function BrainEntryCreatePage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const ownerUID = searchParams.get('owner') ?? defaultBrainOwnerUID(principals.data?.principals ?? [])
  const creatingGuide = searchParams.get('kind') === 'curation-guide'
  const [store, setStore] = useState(creatingGuide ? 'public' : searchParams.get('store') || 'public')
  const [name, setName] = useState(creatingGuide ? t('console.brain.guide_name') : '')
  const [entryType, setEntryType] = useState(creatingGuide ? 'brain_curation_guide' : 'topic')
  const [summary, setSummary] = useState('')
  const [body, setBody] = useState('')
  const [validationError, setValidationError] = useState<string>()
  const create = useMutation({
    ...ankoleWebBrainControllerApplyOperationsMutation(),
    onSuccess: data => {
      toast.success(t('console.brain.created'))
      void queryClient.invalidateQueries()
      const entryID = data.touched_entry_ids[0]
      navigate(entryID ? `/brain/${entryID}?${brainSearch(ownerUID, store)}` : `/brain?${brainSearch(ownerUID, store)}`)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  useEffect(() => {
    if (searchParams.has('owner') || !ownerUID) return
    const next = new URLSearchParams(searchParams)
    next.set('owner', ownerUID)
    setSearchParams(next, { replace: true })
  }, [ownerUID, searchParams, setSearchParams])

  const submit = () => {
    setValidationError(undefined)
    if (!ownerUID || !store.trim() || !name.trim() || !entryType.trim() || !body.trim()) {
      setValidationError(t('console.brain.required_fields'))
      return
    }

    create.mutate({
      query: { owner_uid: ownerUID, store: store.trim() },
      body: {
        operations: [
          {
            operation: 'create_entry',
            name: name.trim(),
            type: entryType.trim(),
            summary,
            initial_body: body.trim()
          }
        ]
      }
    })
  }

  const changeOwner = (value: string) => {
    setSearchParams(setBrainFilter(searchParams, 'owner', value), { replace: true })
    if (store === `dm:${value}`) setStore('public')
  }

  return (
    <ResourceEditorPage
      title={creatingGuide ? t('console.brain.guide_create') : t('console.brain.write_entry')}
      description={creatingGuide ? t('console.brain.guide_editor_description') : t('console.brain.new_description')}
      backTo={`/brain?${brainSearch(ownerUID, store)}`}
      error={validationError ?? create.error ?? principals.error}
      submitting={create.isPending}
      onSubmit={submit}>
      <BrainOwnerField ownerUID={ownerUID} principals={principals.data?.principals ?? []} onChange={changeOwner} />
      {creatingGuide ? (
        <div className="border border-border bg-muted p-4 text-sm leading-6 text-muted-foreground">
          {t('console.brain.guide_scope')}
        </div>
      ) : (
        <>
          <BrainStoreField
            ownerUID={ownerUID}
            store={store}
            principals={principals.data?.principals ?? []}
            onChange={setStore}
          />
          <LabeledField label={t('console.brain.name')}>
            <Input value={name} onChange={event => setName(event.target.value)} />
          </LabeledField>
          <LabeledField label={t('console.brain.type')}>
            <Input list="brain-entry-types" value={entryType} onChange={event => setEntryType(event.target.value)} />
            <datalist id="brain-entry-types">
              <option value="topic" />
              <option value="person" />
              <option value="project" />
              <option value="decision" />
              <option value="preference" />
            </datalist>
          </LabeledField>
        </>
      )}
      <LabeledField label={t('console.brain.body')} description={t('console.brain.body_hint')}>
        <Textarea className="min-h-56" value={body} onChange={event => setBody(event.target.value)} />
      </LabeledField>
      <LabeledField label={t('console.brain.summary')} description={t('console.brain.summary_optional')}>
        <Textarea value={summary} onChange={event => setSummary(event.target.value)} />
      </LabeledField>
    </ResourceEditorPage>
  )
}

export function BrainEntryEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(BrainMetadataEditorModel)
  const params = useParams()
  const [searchParams, setSearchParams] = useSearchParams()
  const entryID = params.id ?? ''
  const ownerUID = searchParams.get('owner') ?? ''
  const auditCursor = searchParams.get('audit_cursor') ?? ''
  const [activeTab, setActiveTab] = useState('edit')
  const detail = useQuery({
    ...ankoleWebBrainControllerShowOptions({ path: { id: entryID }, query: { owner_uid: ownerUID } }),
    enabled: Boolean(entryID && ownerUID),
    retry: false
  })
  const audit = useQuery({
    ...ankoleWebBrainControllerAuditLogOptions({
      path: { id: entryID },
      query: { owner_uid: ownerUID, cursor: auditCursor || undefined, limit: 50 }
    }),
    enabled: Boolean(entryID && ownerUID && activeTab === 'audit'),
    retry: false
  })
  const relationCandidates = useQuery({
    ...ankoleWebBrainControllerIndexOptions({ query: { owner_uid: ownerUID } }),
    enabled: Boolean(ownerUID)
  })
  const entry = detail.data?.entry
  const [validationError, setValidationError] = useState<string>()
  const apply = useMutation({
    ...ankoleWebBrainControllerApplyOperationsMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.saved'))
      setValidationError(undefined)
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const restore = useMutation({
    ...ankoleWebBrainControllerRestoreAuditMutation(),
    onSuccess: data => {
      toast.success(t('console.brain.restored'))
      void queryClient.invalidateQueries()
      if (restorationAction(data.restoration) === 'create_entry') {
        navigate(`/brain?${brainSearch(ownerUID, entry?.store_key)}`)
      }
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const deleteEntry = useMutation({
    ...ankoleWebBrainControllerApplyOperationsMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.deleted'))
      void queryClient.invalidateQueries()
      navigate(`/brain/audit/${entryID}?${brainSearch(ownerUID, entry?.store_key)}`)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  useEffect(() => {
    if (!entry) return
    model.initialize(`entry:${entry.id}`, {
      name: entry.name,
      type: entry.type,
      summary: entry.summary,
      aliases: entry.aliases,
      propertyDrafts: propertiesToDrafts(entry.properties)
    })
  }, [entry, model])

  const applyOperations = (operations: BrainEntryOperation[], onSuccess?: () => void, reason?: string) => {
    if (!entry || operations.length === 0) return
    apply.mutate(
      {
        query: { owner_uid: ownerUID, store: entry.store_key },
        body: { operations, reason: reason?.trim() || undefined }
      },
      { onSuccess }
    )
  }

  const saveMetadata = () => {
    if (!entry) return
    if (!model.name.value.trim() || !model.type.value.trim()) {
      setValidationError(t('console.brain.required_fields'))
      return
    }
    const parsed = parsePropertyDrafts(model.propertyDrafts.value)
    if (!parsed.ok) {
      setValidationError(t('console.brain.invalid_property', { key: parsed.key || '—', detail: parsed.detail }))
      return
    }
    const operations = buildMetadataOperations(entry, {
      name: model.name.value,
      type: model.type.value,
      summary: model.summary.value,
      aliases: model.aliases.value,
      properties: parsed.value
    })
    if (operations.length === 0) {
      toast.info(t('console.brain.no_changes'))
      return
    }
    applyOperations(operations)
  }

  if (detail.isLoading) {
    return (
      <div className="grid gap-4">
        <Skeleton className="h-16 w-2/3" />
        <Skeleton className="h-96 w-full" />
      </div>
    )
  }

  if (detail.error || !entry) {
    return (
      <div className="mx-auto grid max-w-3xl gap-4">
        <PageHeader
          title={t('console.brain.entry_unavailable_title')}
          description={t('console.brain.entry_unavailable')}
        />
        <ErrorBlock
          title={t('console.brain.entry_unavailable_title')}
          error={detail.error ?? t('console.brain.entry_unavailable')}
          action={
            <Button render={<Link to={`/brain?${brainSearch(ownerUID)}`} />} size="sm" variant="outline">
              {t('console.brain.back_to_entries')}
            </Button>
          }
        />
      </div>
    )
  }

  return (
    <ResourceEditorPage
      title={entry.name}
      description={`${entry.type} · ${entry.store_key} · ${t('console.brain.version', { count: entry.lock_version })}`}
      backTo={`/brain?${brainSearch(ownerUID, entry.store_key)}`}
      error={validationError ?? detail.error ?? apply.error ?? restore.error ?? deleteEntry.error}
      submitting={apply.isPending || deleteEntry.isPending}
      submitLabel={t('console.brain.save_metadata')}
      onSubmit={saveMetadata}
      secondary={
        <ConfirmDeleteButton
          pending={deleteEntry.isPending}
          confirm={{
            title: t('console.brain.delete_title'),
            description: t('console.brain.delete_description', { name: entry.name }),
            confirmLabel: t('common.delete')
          }}
          onConfirm={() =>
            deleteEntry.mutate({
              query: { owner_uid: ownerUID, store: entry.store_key },
              body: {
                operations: [
                  {
                    operation: 'delete_entry',
                    entry_id: entry.id,
                    expected_entry_lock_version: entry.lock_version
                  }
                ]
              }
            })
          }
        />
      }>
      <Tabs value={activeTab} onValueChange={setActiveTab} className="grid gap-5">
        <TabsList className="w-full">
          <TabsTrigger value="edit">{t('console.brain.edit')}</TabsTrigger>
          <TabsTrigger value="projection">{t('console.brain.projection')}</TabsTrigger>
          <TabsTrigger value="audit">{t('console.brain.audit')}</TabsTrigger>
        </TabsList>

        <TabsContent value="edit" className="grid gap-6">
          <MetadataEditor
            name={model.name.value}
            type={model.type.value}
            summary={model.summary.value}
            aliases={model.aliases.value}
            propertyDrafts={model.propertyDrafts.value}
            onNameChange={value => {
              model.name.value = value
            }}
            onTypeChange={value => {
              model.type.value = value
            }}
            onSummaryChange={value => {
              model.summary.value = value
            }}
            onAliasesChange={value => {
              model.aliases.value = value
            }}
            onPropertyDraftsChange={value => {
              model.propertyDrafts.value = value
            }}
          />
          <BlocksEditor
            blocks={detail.data?.blocks ?? []}
            entry={entry}
            pending={apply.isPending}
            onApply={applyOperations}
          />
          <RelationsEditor
            relations={detail.data?.relations ?? []}
            backlinks={detail.data?.backlinks ?? []}
            candidates={relationCandidates.data?.entries ?? []}
            entry={entry}
            pending={apply.isPending}
            onApply={applyOperations}
          />
        </TabsContent>

        <TabsContent value="projection" className="grid gap-5">
          <Card>
            <CardHeader>
              <CardTitle>{t('console.brain.current_projection')}</CardTitle>
              <CardDescription>{t('console.brain.projection_description')}</CardDescription>
            </CardHeader>
            <CardContent>
              <pre className="max-h-[60vh] overflow-auto whitespace-pre-wrap border border-border bg-muted p-4 text-sm leading-6">
                {detail.data?.markdown}
              </pre>
            </CardContent>
          </Card>
          <SourceLinks citations={detail.data?.citations ?? []} ownerUID={ownerUID} entryID={entry.id} />
        </TabsContent>

        <TabsContent value="audit">
          <div className="grid gap-4">
            <AuditTrail
              rows={audit.data?.audit_log ?? []}
              loading={audit.isLoading}
              error={audit.error}
              restoring={restore.isPending}
              onRestore={auditID => restore.mutate({ path: { audit_id: auditID }, query: { owner_uid: ownerUID } })}
            />
            <CursorPagination
              page={brainCursorPage(searchParams, 'audit_')}
              hasPrevious={canReturnBrainCursor(searchParams, 'audit_')}
              nextCursor={audit.data?.next_cursor}
              resultCount={audit.data?.audit_log.length ?? 0}
              onPrevious={() => setSearchParams(previousBrainCursor(searchParams, 'audit_'))}
              onNext={nextCursor => setSearchParams(nextBrainCursor(searchParams, nextCursor, 'audit_'))}
            />
          </div>
        </TabsContent>
      </Tabs>
    </ResourceEditorPage>
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
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <div className="mx-auto grid max-w-3xl gap-5">
      <Link
        to={`/brain?${brainSearch(ownerUID, store)}`}
        className="w-fit text-sm text-muted-foreground hover:text-foreground">
        ← {t('common.back')}
      </Link>
      <div>
        <h2 className="text-2xl font-semibold">{t('console.brain.deleted_audit_title')}</h2>
        <p className="break-all font-mono text-xs text-muted-foreground">{entryID}</p>
      </div>
      <p className="text-sm text-muted-foreground">{t('console.brain.deleted_audit_description')}</p>
      <AuditTrail
        rows={audit.data?.audit_log ?? []}
        loading={audit.isLoading}
        error={audit.error ?? restore.error}
        restoring={restore.isPending}
        onRestore={auditID => restore.mutate({ path: { audit_id: auditID }, query: { owner_uid: ownerUID } })}
      />
      <CursorPagination
        page={brainCursorPage(searchParams, 'audit_')}
        hasPrevious={canReturnBrainCursor(searchParams, 'audit_')}
        nextCursor={audit.data?.next_cursor}
        resultCount={audit.data?.audit_log.length ?? 0}
        onPrevious={() => setSearchParams(previousBrainCursor(searchParams, 'audit_'))}
        onNext={nextCursor => setSearchParams(nextBrainCursor(searchParams, nextCursor, 'audit_'))}
      />
    </div>
  )
}

function SourceLinks({
  citations,
  ownerUID,
  entryID
}: {
  citations: BrainCitation[]
  ownerUID: string
  entryID: string
}) {
  const { t } = useTranslation()
  const documents = [...new Set(citations.map(citation => citation.document_id))]
  if (documents.length === 0) return null
  return (
    <Card>
      <CardHeader>
        <CardTitle>{t('console.brain.sources')}</CardTitle>
      </CardHeader>
      <CardContent className="grid gap-2">
        {documents.map(documentID => (
          <Link
            key={documentID}
            to={`/brain/sources/${encodeURIComponent(documentID)}?owner=${encodeURIComponent(ownerUID)}&entry=${encodeURIComponent(entryID)}`}
            className="flex items-center gap-2 border border-border px-3 py-2 font-mono text-xs text-primary hover:bg-muted">
            <RiExternalLinkLine />
            {documentID}
          </Link>
        ))}
      </CardContent>
    </Card>
  )
}

function FilterDisclosure({ count, onClear, children }: { count: number; onClear: () => void; children: ReactNode }) {
  const { t } = useTranslation()
  return (
    <Collapsible defaultOpen={count > 0} className="grid gap-3 border-t border-border pt-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <CollapsibleTrigger className="inline-flex h-9 items-center gap-2 px-2 text-sm font-medium outline-none hover:bg-muted focus-visible:ring-2 focus-visible:ring-ring/40">
          <RiFilter3Line aria-hidden />
          {t('console.brain.more_filters')}
          {count > 0 ? <Badge variant="info">{count}</Badge> : null}
          <RiArrowDownSLine aria-hidden />
        </CollapsibleTrigger>
        {count > 0 ? (
          <Button type="button" size="xs" variant="ghost" onClick={onClear}>
            {t('console.brain.clear_filters')}
          </Button>
        ) : null}
      </div>
      <CollapsibleContent>{children}</CollapsibleContent>
    </Collapsible>
  )
}

function dreamingStatusTone(status: string): 'neutral' | 'positive' | 'warning' {
  if (status === 'completed') return 'positive'
  if (status === 'already_running') return 'warning'
  return 'neutral'
}

function DreamingFitnessCard({ ownerUID, onSelectRun }: { ownerUID: string; onSelectRun: (runID: string) => void }) {
  const { t } = useTranslation()
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
              value={horizonDays}
              onChange={event => {
                const next = Number.parseInt(event.target.value, 10)
                if (Number.isFinite(next) && next >= 1 && next <= 90) setHorizonDays(next)
              }}
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
          className="truncate text-left font-mono text-xs text-primary hover:underline"
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
      <span className="text-right text-xs text-muted-foreground">{formatBrainDate(run.last_written_at)}</span>
    </div>
  )
}

function formatPercent(rate?: number | null): string {
  if (rate === null || rate === undefined) return '—'
  return `${(rate * 100).toFixed(1)}%`
}

function AuditTrail({
  rows,
  loading,
  error,
  restoring,
  onRestore,
  selectedIDs,
  onSelectedChange,
  entryHref
}: {
  rows: BrainAuditLog[]
  loading: boolean
  error: unknown
  restoring: boolean
  onRestore?: (auditID: string) => void
  selectedIDs?: Set<string>
  onSelectedChange?: (auditID: string, selected: boolean) => void
  entryHref?: (row: BrainAuditLog) => string | undefined
}) {
  const { t } = useTranslation()
  if (loading) return <Skeleton className="h-72 w-full" />
  if (error) return <ErrorBlock error={error} />
  if (rows.length === 0) return <p className="text-sm text-muted-foreground">{t('console.brain.no_audit')}</p>
  return (
    <div className="grid gap-3">
      {rows.map(row => {
        const restorable = RESTORABLE_AUDIT_ACTIONS.has(row.action)
        const href = entryHref?.(row)
        const runID = typeof row.metadata.run_id === 'string' ? row.metadata.run_id : undefined

        return (
          <Card key={row.id}>
            <CardHeader>
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="flex min-w-0 items-start gap-3">
                  {onSelectedChange && restorable ? (
                    <Checkbox
                      className="mt-1"
                      checked={selectedIDs?.has(row.id) ?? false}
                      aria-label={t('console.brain.select_audit', { action: row.action })}
                      onCheckedChange={checked => onSelectedChange(row.id, checked === true)}
                    />
                  ) : null}
                  <div className="min-w-0">
                    <CardTitle className="flex flex-wrap items-center gap-2">
                      <RiHistoryLine />
                      {row.action}
                    </CardTitle>
                    <CardDescription>
                      {row.store_key} · {row.actor_kind} · {row.actor_uid || '—'} · {formatBrainDate(row.inserted_at)}
                    </CardDescription>
                    <div className="mt-1 flex flex-wrap gap-x-3 gap-y-1 font-mono text-xs text-muted-foreground">
                      <span>{row.id}</span>
                      {href && row.entry_id ? (
                        <Link to={href} className="text-primary hover:underline">
                          {t('console.brain.audit_entry')}: {row.entry_id}
                        </Link>
                      ) : null}
                      {runID ? (
                        <span>
                          {t('console.brain.audit_run')}: {runID}
                        </span>
                      ) : null}
                    </div>
                  </div>
                </div>
                {restorable && onRestore ? (
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    disabled={restoring}
                    onClick={() => onRestore(row.id)}>
                    <RiRefreshLine />
                    {t('console.brain.restore')}
                  </Button>
                ) : null}
              </div>
            </CardHeader>
            <CardContent className="grid gap-3 md:grid-cols-2">
              <AuditSnapshot title={t('console.brain.before')} value={row.before} />
              <AuditSnapshot title={t('console.brain.after')} value={row.after} />
            </CardContent>
          </Card>
        )
      })}
    </div>
  )
}

function AuditSnapshot({ title, value }: { title: string; value?: Record<string, unknown> | null }) {
  const { t } = useTranslation()
  const fields = value ? Object.entries(value) : []
  return (
    <section className="grid min-w-0 gap-1">
      <h4 className="text-xs font-medium text-muted-foreground">{title}</h4>
      {value ? (
        <div className="border border-border bg-card">
          <dl className="divide-y divide-border">
            {fields.map(([key, fieldValue]) => (
              <div key={key} className="grid gap-1 px-3 py-2 sm:grid-cols-[minmax(8rem,1fr)_2fr] sm:gap-3">
                <dt className="break-all font-mono text-xs text-muted-foreground">{key}</dt>
                <dd className="break-all text-xs">{auditValuePreview(fieldValue)}</dd>
              </div>
            ))}
          </dl>
          <details className="border-t border-border">
            <summary className="cursor-pointer px-3 py-2 text-xs font-medium text-muted-foreground hover:bg-muted">
              {t('console.brain.raw_json')}
            </summary>
            <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-all border-t border-border bg-muted p-3 text-xs">
              {formatJSON(value)}
            </pre>
          </details>
        </div>
      ) : (
        <div className="border border-border bg-muted p-3 text-xs text-muted-foreground">—</div>
      )}
    </section>
  )
}

function auditValuePreview(value: unknown): string {
  if (value === null) return 'null'
  if (typeof value === 'string') return value || '""'
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  if (Array.isArray(value)) return `[${value.length}] ${truncateText(JSON.stringify(value), 180)}`
  if (typeof value === 'object') return truncateText(JSON.stringify(value), 180)
  return String(value)
}

function truncateText(value: string, limit: number): string {
  return value.length <= limit ? value : `${value.slice(0, limit)}…`
}

function CursorPagination({
  page,
  hasPrevious,
  nextCursor,
  resultCount,
  onPrevious,
  onNext
}: {
  page: number
  hasPrevious: boolean
  nextCursor?: string | null
  resultCount: number
  onPrevious: () => void
  onNext: (cursor: string) => void
}) {
  const { t } = useTranslation()

  return (
    <div className="flex flex-wrap items-center justify-between gap-3">
      <span className="text-xs text-muted-foreground">
        {t('console.brain.page_results', { page, count: resultCount })}
      </span>
      <div className="flex items-center gap-2">
        <Button type="button" size="sm" variant="outline" disabled={!hasPrevious} onClick={onPrevious}>
          {t('console.brain.previous_page')}
        </Button>
        <Button
          type="button"
          size="sm"
          variant="outline"
          disabled={!nextCursor}
          onClick={() => nextCursor && onNext(nextCursor)}>
          {t('console.brain.next_page')}
        </Button>
      </div>
    </div>
  )
}

function localDateStartISO(value: string): string | undefined {
  if (!value) return undefined
  const date = new Date(`${value}T00:00:00`)
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString()
}

function localDateEndISO(value: string): string | undefined {
  if (!value) return undefined
  const date = new Date(`${value}T00:00:00`)
  if (Number.isNaN(date.getTime())) return undefined
  date.setDate(date.getDate() + 1)
  date.setMilliseconds(date.getMilliseconds() - 1)
  return date.toISOString()
}

function restorationAction(restoration: unknown): string | undefined {
  if (!restoration || typeof restoration !== 'object' || Array.isArray(restoration)) return undefined
  const action = (restoration as Record<string, unknown>).restored
  return typeof action === 'string' ? action : undefined
}
