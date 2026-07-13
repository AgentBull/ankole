import {
  Badge,
  Button,
  Checkbox,
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
  buttonVariants,
  cn,
  toast
} from '@ankole/uikit'
import { RiExternalLinkLine, RiHistoryLine, RiRefreshLine, RiSparkling2Line } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebAgentControllerIndexOptions,
  ankoleWebBrainControllerApplyOperationsMutation,
  ankoleWebBrainControllerAuditIndexOptions,
  ankoleWebBrainControllerAuditLogOptions,
  ankoleWebBrainControllerIndexOptions,
  ankoleWebBrainControllerRestoreAuditMutation,
  ankoleWebBrainControllerRestoreAuditsMutation,
  ankoleWebBrainControllerRunDreamingMutation,
  ankoleWebBrainControllerShowOptions,
  ankoleWebBrainControllerSourceOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { BrainAuditLog, BrainEntryOperation } from '../api/generated/types.gen'
import { ErrorBlock, formatJSON, parseObjectDraft } from '../console-primitives'
import { ConfirmDeleteButton, LabeledField, ResourceEditorPage, ResourceListPage } from '../console-shell'
import { BlocksEditor, MetadataEditor, RelationsEditor } from './brain-entry-editors'
import {
  brainCursorPage,
  buildMetadataOperations,
  canReturnBrainCursor,
  nextBrainCursor,
  normalizeAliases,
  parsePropertyDrafts,
  previousBrainCursor,
  propertiesToDrafts,
  setBrainFilter,
  sourceDocumentIDs,
  type PropertyDraft
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
  'add_relation',
  'remove_relation'
])

export function BrainEntriesPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const ownerUID = searchParams.get('owner') ?? agents.data?.agents[0]?.uid ?? ''
  const entryType = searchParams.get('type') ?? ''
  const query = searchParams.get('q') ?? ''
  const store = searchParams.get('store') ?? ''
  const author = searchParams.get('author') ?? ''
  const updated = searchParams.get('updated') ?? ''
  const cursor = searchParams.get('cursor') ?? ''
  const [dreamingOwnerUID, setDreamingOwnerUID] = useState('')
  const runDreaming = useMutation({
    ...ankoleWebBrainControllerRunDreamingMutation(),
    onSuccess: data => toast.success(t('console.brain.dreaming_finished', { status: data.run.status })),
    onError: error => toast.error(requestErrorMessage(error))
  })
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
  const entries = list.data?.entries ?? []

  useEffect(() => {
    if (searchParams.has('owner') || !ownerUID) return
    const next = new URLSearchParams(searchParams)
    next.set('owner', ownerUID)
    setSearchParams(next, { replace: true })
  }, [ownerUID, searchParams, setSearchParams])

  const setFilter = (key: string, value: string) => {
    setSearchParams(setBrainFilter(searchParams, key, value), { replace: true })
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
      createLabel={t('console.brain.new')}
      createTo={`new?${brainSearch(ownerUID, store || 'public')}`}
      isLoading={list.isLoading || agents.isLoading}
      isEmpty={entries.length === 0}
      emptyTitle={t('console.brain.empty_title')}
      emptyDescription={t('console.brain.empty_description')}
      error={list.error ?? agents.error ?? runDreaming.error}
      toolbar={
        <div className="grid gap-4 border border-border bg-card p-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div className="text-sm text-muted-foreground">
              {runDreaming.data && dreamingOwnerUID === ownerUID
                ? t('console.brain.dreaming_result', {
                    status: runDreaming.data.run.status,
                    materials: runDreaming.data.run.material_count ?? 0,
                    operations: runDreaming.data.run.operation_count ?? 0
                  })
                : t('console.brain.dreaming_description')}
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <Link
                to={`audit?${brainSearch(ownerUID, store || undefined)}`}
                className={cn(buttonVariants({ size: 'sm', variant: 'outline' }))}>
                <RiHistoryLine />
                {t('console.brain.open_audit')}
              </Link>
              <Button
                type="button"
                size="sm"
                variant="outline"
                disabled={!ownerUID || runDreaming.isPending}
                onClick={() => {
                  runDreaming.reset()
                  setDreamingOwnerUID(ownerUID)
                  runDreaming.mutate({ query: { owner_uid: ownerUID } })
                }}>
                <RiSparkling2Line />
                {runDreaming.isPending && dreamingOwnerUID === ownerUID
                  ? t('console.brain.dreaming_running')
                  : t('console.brain.run_dreaming')}
              </Button>
            </div>
          </div>
          <div className="grid gap-3 md:grid-cols-3 xl:grid-cols-6">
            <LabeledField label={t('console.brain.search')}>
              <Input
                value={query}
                placeholder={t('console.brain.search_placeholder')}
                onChange={event => setFilter('q', event.target.value)}
              />
            </LabeledField>
            <LabeledField label={t('console.brain.owner')}>
              <Input
                list="brain-owner-uids"
                value={ownerUID}
                placeholder={t('console.brain.owner_placeholder')}
                onChange={event => setFilter('owner', event.target.value)}
              />
              <datalist id="brain-owner-uids">
                {(agents.data?.agents ?? []).map(agent => (
                  <option key={agent.uid} value={agent.uid}>
                    {agent.display_name || agent.uid}
                  </option>
                ))}
              </datalist>
            </LabeledField>
            <LabeledField label={t('console.brain.type')}>
              <Input value={entryType} onChange={event => setFilter('type', event.target.value)} />
            </LabeledField>
            <LabeledField label={t('console.brain.store')}>
              <Input value={store} placeholder="public" onChange={event => setFilter('store', event.target.value)} />
            </LabeledField>
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
          <CursorPagination
            page={brainCursorPage(searchParams)}
            hasPrevious={canReturnBrainCursor(searchParams)}
            nextCursor={list.data?.next_cursor}
            resultCount={entries.length}
            onPrevious={() => setSearchParams(previousBrainCursor(searchParams))}
            onNext={nextCursor => setSearchParams(nextBrainCursor(searchParams, nextCursor))}
          />
        </div>
      }>
      {entries.map(entry => (
        <TableRow
          key={entry.id}
          className="cursor-pointer"
          onClick={() => navigate(`${entry.id}?${brainSearch(ownerUID, entry.store_key)}`)}>
          <TableCell className="font-medium">{entry.name}</TableCell>
          <TableCell>
            <Badge variant="secondary">{entry.type}</Badge>
          </TableCell>
          <TableCell className="font-mono text-xs">{entry.store_key}</TableCell>
          <TableCell className="max-w-md truncate text-muted-foreground">{entry.summary || '—'}</TableCell>
          <TableCell className="whitespace-nowrap text-xs text-muted-foreground">
            {formatDate(entry.updated_at)}
          </TableCell>
          <TableCell className="text-right">
            <Link
              to={`${entry.id}?${brainSearch(ownerUID, entry.store_key)}`}
              onClick={event => event.stopPropagation()}
              className="text-sm text-primary hover:underline">
              {t('common.edit')}
            </Link>
          </TableCell>
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

export function BrainAuditPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const ownerUID = searchParams.get('owner') ?? agents.data?.agents[0]?.uid ?? ''
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
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="grid gap-1">
          <Link
            to={`/brain?${brainSearch(ownerUID, store || undefined)}`}
            className="w-fit text-sm text-muted-foreground hover:text-foreground">
            ← {t('common.back')}
          </Link>
          <h2 className="text-2xl font-semibold">{t('console.brain.audit_title')}</h2>
          <p className="max-w-3xl text-sm leading-6 text-muted-foreground">{t('console.brain.audit_description')}</p>
        </div>
        <Button
          type="button"
          variant="outline"
          disabled={selectedIDs.size === 0 || restore.isPending}
          onClick={() => setConfirmOpen(true)}>
          <RiRefreshLine />
          {t('console.brain.restore_selected', { count: selectedIDs.size })}
        </Button>
      </div>

      <div className="grid gap-4 border border-border bg-card p-4">
        <div className="grid gap-3 md:grid-cols-3 xl:grid-cols-4">
          <LabeledField label={t('console.brain.owner')}>
            <Input
              list="brain-audit-owner-uids"
              value={ownerUID}
              placeholder={t('console.brain.owner_placeholder')}
              onChange={event => setFilter('owner', event.target.value)}
            />
            <datalist id="brain-audit-owner-uids">
              {(agents.data?.agents ?? []).map(agent => (
                <option key={agent.uid} value={agent.uid}>
                  {agent.display_name || agent.uid}
                </option>
              ))}
            </datalist>
          </LabeledField>
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

      <ErrorBlock error={audit.error ?? agents.error ?? restore.error} />
      <AuditTrail
        rows={rows}
        loading={audit.isLoading || agents.isLoading}
        error={undefined}
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

export function BrainEntryCreatePage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [searchParams] = useSearchParams()
  const ownerUID = searchParams.get('owner') ?? ''
  const [store, setStore] = useState(searchParams.get('store') || 'public')
  const [name, setName] = useState('')
  const [entryType, setEntryType] = useState('')
  const [summary, setSummary] = useState('')
  const [aliases, setAliases] = useState('')
  const [properties, setProperties] = useState('{}')
  const [validationError, setValidationError] = useState<string>()
  const create = useMutation({
    ...ankoleWebBrainControllerApplyOperationsMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.created'))
      void queryClient.invalidateQueries()
      navigate(`../?${brainSearch(ownerUID, store)}`)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const submit = () => {
    setValidationError(undefined)
    if (!ownerUID || !store.trim() || !name.trim() || !entryType.trim()) {
      setValidationError(t('console.brain.required_fields'))
      return
    }
    const parsed = parseObjectDraft(properties, t('console.brain.properties'))
    if (!parsed.ok) {
      setValidationError(parsed.error)
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
            aliases: normalizeAliases(aliases.split(/[\n,]/)),
            properties: parsed.value
          }
        ]
      }
    })
  }

  return (
    <ResourceEditorPage
      title={t('console.brain.new')}
      description={t('console.brain.new_description')}
      backTo={`../?${brainSearch(ownerUID, store)}`}
      error={validationError ?? create.error}
      submitting={create.isPending}
      onSubmit={submit}>
      <LabeledField label={t('console.brain.owner')}>
        <Input value={ownerUID} disabled />
      </LabeledField>
      <LabeledField label={t('console.brain.store')}>
        <Input value={store} onChange={event => setStore(event.target.value)} />
      </LabeledField>
      <LabeledField label={t('console.brain.name')}>
        <Input value={name} onChange={event => setName(event.target.value)} />
      </LabeledField>
      <LabeledField label={t('console.brain.type')}>
        <Input value={entryType} onChange={event => setEntryType(event.target.value)} />
      </LabeledField>
      <LabeledField label={t('console.brain.summary')}>
        <Textarea value={summary} onChange={event => setSummary(event.target.value)} />
      </LabeledField>
      <LabeledField label={t('console.brain.aliases')} description={t('console.brain.aliases_hint')}>
        <Textarea value={aliases} onChange={event => setAliases(event.target.value)} />
      </LabeledField>
      <LabeledField label={t('console.brain.properties')}>
        <Textarea
          className="min-h-40 font-mono text-xs"
          value={properties}
          onChange={event => setProperties(event.target.value)}
        />
      </LabeledField>
    </ResourceEditorPage>
  )
}

export function BrainEntryEditorPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const params = useParams()
  const [searchParams, setSearchParams] = useSearchParams()
  const entryID = params.id ?? ''
  const ownerUID = searchParams.get('owner') ?? ''
  const auditCursor = searchParams.get('audit_cursor') ?? ''
  const [activeTab, setActiveTab] = useState('edit')
  const detail = useQuery({
    ...ankoleWebBrainControllerShowOptions({ path: { id: entryID }, query: { owner_uid: ownerUID } }),
    enabled: Boolean(entryID && ownerUID)
  })
  const audit = useQuery({
    ...ankoleWebBrainControllerAuditLogOptions({
      path: { id: entryID },
      query: { owner_uid: ownerUID, cursor: auditCursor || undefined, limit: 50 }
    }),
    enabled: Boolean(entryID && ownerUID && activeTab === 'audit')
  })
  const relationCandidates = useQuery({
    ...ankoleWebBrainControllerIndexOptions({ query: { owner_uid: ownerUID } }),
    enabled: Boolean(ownerUID)
  })
  const entry = detail.data?.entry
  const [summary, setSummary] = useState('')
  const [aliases, setAliases] = useState<string[]>([])
  const [propertyDrafts, setPropertyDrafts] = useState<PropertyDraft[]>([])
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
        navigate(`../?${brainSearch(ownerUID, entry?.store_key)}`)
      }
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const deleteEntry = useMutation({
    ...ankoleWebBrainControllerApplyOperationsMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.deleted'))
      void queryClient.invalidateQueries()
      navigate(`../audit/${entryID}?${brainSearch(ownerUID, entry?.store_key)}`)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  useEffect(() => {
    if (!entry) return
    setSummary(entry.summary)
    setAliases(entry.aliases)
    setPropertyDrafts(propertiesToDrafts(entry.properties))
  }, [entry])

  const applyOperations = (operations: BrainEntryOperation[], onSuccess?: () => void) => {
    if (!entry || operations.length === 0) return
    apply.mutate(
      {
        query: { owner_uid: ownerUID, store: entry.store_key },
        body: { operations }
      },
      { onSuccess }
    )
  }

  const saveMetadata = () => {
    if (!entry) return
    const parsed = parsePropertyDrafts(propertyDrafts)
    if (!parsed.ok) {
      setValidationError(t('console.brain.invalid_property', { key: parsed.key || '—', detail: parsed.detail }))
      return
    }
    const operations = buildMetadataOperations(entry, { summary, aliases, properties: parsed.value })
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
        <Link to={`../?${brainSearch(ownerUID)}`} className="w-fit text-sm text-muted-foreground hover:text-foreground">
          ← {t('common.back')}
        </Link>
        <ErrorBlock error={detail.error ?? t('console.brain.entry_unavailable')} />
      </div>
    )
  }

  return (
    <ResourceEditorPage
      title={entry.name}
      description={`${entry.type} · ${entry.store_key} · ${t('console.brain.version', { count: entry.lock_version })}`}
      backTo={`../?${brainSearch(ownerUID, entry.store_key)}`}
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
            entry={entry}
            summary={summary}
            aliases={aliases}
            propertyDrafts={propertyDrafts}
            onSummaryChange={setSummary}
            onAliasesChange={setAliases}
            onPropertyDraftsChange={setPropertyDrafts}
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
          <SourceLinks markdown={detail.data?.markdown ?? ''} ownerUID={ownerUID} entryID={entry.id} />
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
    enabled: Boolean(entryID && ownerUID)
  })
  const restore = useMutation({
    ...ankoleWebBrainControllerRestoreAuditMutation(),
    onSuccess: data => {
      toast.success(t('console.brain.restored'))
      void queryClient.invalidateQueries()
      if (restorationAction(data.restoration) === 'delete_entry') {
        navigate(`../../${entryID}?${brainSearch(ownerUID, store)}`)
      }
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <div className="mx-auto grid max-w-3xl gap-5">
      <Link
        to={`../../?${brainSearch(ownerUID, store)}`}
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

function SourceLinks({ markdown, ownerUID, entryID }: { markdown: string; ownerUID: string; entryID: string }) {
  const { t } = useTranslation()
  const documents = useMemo(() => sourceDocumentIDs(markdown), [markdown])
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
            to={`../sources/${encodeURIComponent(documentID)}?owner=${encodeURIComponent(ownerUID)}&entry=${encodeURIComponent(entryID)}`}
            className="flex items-center gap-2 border border-border px-3 py-2 font-mono text-xs text-primary hover:bg-muted">
            <RiExternalLinkLine />
            {documentID}
          </Link>
        ))}
      </CardContent>
    </Card>
  )
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
  return (
    <div className="grid gap-3">
      <ErrorBlock error={error} />
      {rows.length === 0 ? <p className="text-sm text-muted-foreground">{t('console.brain.no_audit')}</p> : null}
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
                      {row.store_key} · {row.actor_kind} · {row.actor_uid || '—'} · {formatDate(row.inserted_at)}
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
  return (
    <section className="grid min-w-0 gap-1">
      <h4 className="text-xs font-medium text-muted-foreground">{title}</h4>
      <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-all border border-border bg-muted p-3 text-xs">
        {value ? formatJSON(value) : '—'}
      </pre>
    </section>
  )
}

export function BrainSourcePage() {
  const { t } = useTranslation()
  const params = useParams()
  const [searchParams] = useSearchParams()
  const documentID = params.documentID ?? ''
  const ownerUID = searchParams.get('owner') ?? ''
  const entryID = searchParams.get('entry') ?? ''
  const source = useQuery({
    ...ankoleWebBrainControllerSourceOptions({ path: { document_id: documentID } }),
    enabled: Boolean(documentID)
  })
  const item = source.data?.source
  return (
    <div className="mx-auto grid max-w-3xl gap-5">
      <Link
        to={entryID ? `../../${entryID}?${brainSearch(ownerUID)}` : '../../'}
        className="w-fit text-sm text-muted-foreground hover:text-foreground">
        ← {t('common.back')}
      </Link>
      <div>
        <h2 className="text-2xl font-semibold">{t('console.brain.source_title')}</h2>
        <p className="break-all font-mono text-xs text-muted-foreground">{documentID}</p>
      </div>
      <ErrorBlock error={source.error} />
      {source.isLoading ? (
        <Skeleton className="h-72 w-full" />
      ) : item ? (
        <Card>
          <CardHeader>
            <CardTitle>{sourceAuthor(item.author)}</CardTitle>
            <CardDescription>
              {item.signal_channel_id} · {formatDate(item.provider_time)}
            </CardDescription>
          </CardHeader>
          <CardContent className="grid gap-4">
            <p className="whitespace-pre-wrap text-sm leading-6">{item.text || '—'}</p>
            <details>
              <summary className="cursor-pointer text-sm text-muted-foreground">
                {t('console.brain.source_metadata')}
              </summary>
              <pre className="mt-2 max-h-80 overflow-auto whitespace-pre-wrap break-all bg-muted p-3 text-xs">
                {formatJSON({
                  formatted_content: item.formatted_content,
                  attachments: item.attachments,
                  links: item.links,
                  metadata: item.metadata
                })}
              </pre>
            </details>
          </CardContent>
        </Card>
      ) : null}
    </div>
  )
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

function brainSearch(ownerUID: string, store?: string): string {
  const params = new URLSearchParams()
  if (ownerUID) params.set('owner', ownerUID)
  if (store) params.set('store', store)
  return params.toString()
}

function formatDate(value?: string | null): string {
  if (!value) return '—'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date)
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

function sourceAuthor(author: Record<string, unknown>): string {
  for (const key of ['display_name', 'name', 'principal_uid', 'id']) {
    if (typeof author[key] === 'string' && author[key]) return String(author[key])
  }
  return '—'
}

function restorationAction(restoration: unknown): string | undefined {
  if (!restoration || typeof restoration !== 'object' || Array.isArray(restoration)) return undefined
  const action = (restoration as Record<string, unknown>).restored
  return typeof action === 'string' ? action : undefined
}
