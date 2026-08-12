import {
  Badge,
  buttonVariants,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  cn,
  Input,
  Skeleton,
  TableCell,
  TableRow,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  Textarea,
  toast
} from '@ankole/uikit'
import { RiBrainLine, RiExternalLinkLine } from '@remixicon/react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebBrainControllerApplyOperationsMutation,
  ankoleWebBrainControllerAuditLogOptions,
  ankoleWebBrainControllerIndexOptions,
  ankoleWebBrainControllerRestoreAuditMutation,
  ankoleWebBrainControllerShowOptions,
  ankoleWebBrainControllerShowQueryKey,
  ankoleWebPrincipalControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { BrainCitation, BrainEntry, BrainEntryOperation, BrainEntryResponse } from '../api/generated/types.gen'
import { PageHeader, PageStack } from '../console-page'
import { ErrorBlock } from '../../common/error-block'
import { formatConsoleDate } from '../console-primitives'
import { ConfirmDeleteButton, LabeledField, ResourceEditorPage } from '../console-form'
import { CursorPagination, ResourceListPage, RowActions, SearchField } from '../console-list-page'
import { BlocksEditor, MetadataEditor, RelationsEditor } from './brain-entry-editors'
import {
  AuditTrail,
  type ActiveFilter,
  BrainOwnerField,
  BrainStoreField,
  BrainStoreName,
  BrainTaskNavigation,
  FilterDisclosure,
  brainSearch,
  localDateStartISO,
  restorationAction
} from './brain-shared'
import {
  BrainMetadataEditorModel,
  buildMetadataOperations,
  defaultBrainOwnerUID,
  parsePropertyDrafts,
  propertiesToDrafts,
  setBrainFilter
} from '../state/brain-editor-model'
import {
  cursorPageNumber,
  hasPreviousCursor,
  nextCursorParams,
  previousCursorParams,
  resetCursorParams
} from '../state/cursor-pagination'

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
    enabled: Boolean(ownerUID),
    placeholderData: keepPreviousData
  })
  const guide = useQuery({
    ...ankoleWebBrainControllerIndexOptions({
      query: { owner_uid: ownerUID, store: 'self', type: 'brain_curation_guide', limit: 1 }
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
    for (const key of ['type', 'store', 'author', 'updated']) next.delete(key)
    setSearchParams(resetCursorParams(next), { replace: true })
  }

  const activeAdvancedFilters: ActiveFilter[] = []
  if (entryType) {
    activeAdvancedFilters.push({
      id: 'type',
      label: t('console.brain.type'),
      value: entryType,
      onRemove: () => setFilter('type', '')
    })
  }
  if (store) {
    activeAdvancedFilters.push({
      id: 'store',
      label: t('console.brain.store'),
      value:
        store === 'shared' ? t('console.brain.store_shared') : store === 'self' ? t('console.brain.store_self') : store,
      onRemove: () => setFilter('store', '')
    })
  }
  if (author) {
    activeAdvancedFilters.push({
      id: 'author',
      label: t('console.brain.author'),
      value: author,
      onRemove: () => setFilter('author', '')
    })
  }
  if (updated) {
    activeAdvancedFilters.push({
      id: 'updated',
      label: t('console.brain.updated_after'),
      value: updated,
      onRemove: () => setFilter('updated', '')
    })
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
      createTo={`new?${brainSearch(ownerUID, store || 'shared')}`}
      isLoading={list.isLoading || principals.isLoading}
      isEmpty={entries.length === 0}
      emptyTitle={t('console.brain.empty_title')}
      emptyIcon={<RiBrainLine aria-hidden />}
      emptyDescription={t('console.brain.empty_description')}
      onClearFilters={clearFilters}
      isFiltered={isFiltered}
      error={list.error ?? guide.error ?? principals.error}
      subNav={<BrainTaskNavigation ownerUID={ownerUID} store={store || undefined} />}
      toolbarCanRevealRows
      footer={
        entries.length > 0 || hasPreviousCursor(searchParams) ? (
          <CursorPagination
            page={cursorPageNumber(searchParams)}
            hasPrevious={hasPreviousCursor(searchParams)}
            nextCursor={list.data?.next_cursor}
            resultCount={entries.length}
            onPrevious={() => setSearchParams(previousCursorParams(searchParams))}
            onNext={nextCursor => setSearchParams(nextCursorParams(searchParams, nextCursor))}
          />
        ) : undefined
      }
      toolbar={
        <div className="grid gap-4 border border-border bg-card p-4">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-border pb-4">
            <div className="grid gap-1">
              <h3 className="text-sm font-medium">{t('console.brain.guide_title')}</h3>
              <p className="text-sm text-muted-foreground">{t('console.brain.guide_description')}</p>
            </div>
            {/* The create link waits for the guide query, so a slow load cannot
                offer to create a second guide beside an existing one. */}
            {guideEntry || guide.isSuccess ? (
              <Link
                className={cn(buttonVariants({ size: 'sm', variant: 'outline' }))}
                to={
                  guideEntry
                    ? `/brain/${guideEntry.id}?${brainSearch(ownerUID, 'self')}`
                    : `/brain/new?${brainSearch(ownerUID, 'self')}&kind=curation-guide`
                }>
                {guideEntry ? t('console.brain.guide_edit') : t('console.brain.guide_create')}
              </Link>
            ) : null}
          </div>
          <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
            <LabeledField label={t('console.brain.search')}>
              <SearchField
                label={t('console.brain.search')}
                value={query}
                placeholder={t('console.brain.search_placeholder')}
                onChange={value => setFilter('q', value)}
              />
            </LabeledField>
            <BrainOwnerField
              ownerUID={ownerUID}
              principals={principals.data?.principals ?? []}
              onChange={value => setFilter('owner', value)}
            />
          </div>
          <FilterDisclosure filters={activeAdvancedFilters} onClear={clearAdvancedFilters}>
            <div className="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-4">
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
        </div>
      }>
      {entries.map(entry => (
        <TableRow key={entry.id}>
          <TableCell className="font-medium">
            <Link to={`${entry.id}?${brainSearch(ownerUID, entry.store_key)}`} className="text-link hover:underline">
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
            {formatConsoleDate(entry.updated_at)}
          </TableCell>
          <RowActions editLabel={t('common.edit')} editTo={`${entry.id}?${brainSearch(ownerUID, entry.store_key)}`} />
        </TableRow>
      ))}
    </ResourceListPage>
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
  const [store, setStore] = useState(creatingGuide ? 'self' : searchParams.get('store') || 'shared')
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
    if (store === `dm:${value}`) setStore('shared')
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
          <LabeledField label={t('console.brain.name')} required>
            <Input required value={name} onChange={event => setName(event.target.value)} />
          </LabeledField>
          <LabeledField label={t('console.brain.type')} required>
            <Input
              required
              list="brain-entry-types"
              value={entryType}
              onChange={event => setEntryType(event.target.value)}
            />
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
      <LabeledField label={t('console.brain.body')} description={t('console.brain.body_hint')} required>
        <Textarea required className="min-h-56" value={body} onChange={event => setBody(event.target.value)} />
      </LabeledField>
      <LabeledField label={t('console.brain.summary')} description={t('console.brain.summary_optional')}>
        <Textarea value={summary} onChange={event => setSummary(event.target.value)} />
      </LabeledField>
    </ResourceEditorPage>
  )
}

/** The editable metadata drafts, as one entry snapshot maps into the model. */
function metadataDraft(entry: BrainEntry) {
  return {
    name: entry.name,
    type: entry.type,
    summary: entry.summary,
    aliases: entry.aliases,
    propertyDrafts: propertiesToDrafts(entry.properties)
  }
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
    onSuccess: async data => {
      toast.success(t('console.brain.restored'))
      if (restorationAction(data.restoration) === 'create_entry') {
        void queryClient.invalidateQueries()
        navigate(`/brain?${brainSearch(ownerUID, entry?.store_key)}`)
        return
      }
      // Rebaseline the drafts from the restored entry once the refetch lands.
      // The sourceKey guard keeps the stale pre-restore drafts otherwise, and
      // the next save would diff them against the restored entry and undo it.
      await queryClient.invalidateQueries()
      const fresh = queryClient.getQueryData<BrainEntryResponse>(
        ankoleWebBrainControllerShowQueryKey({ path: { id: entryID }, query: { owner_uid: ownerUID } })
      )?.entry
      if (fresh) {
        model.sourceKey.value = undefined
        model.initialize(`entry:${fresh.id}`, metadataDraft(fresh))
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
    model.initialize(`entry:${entry.id}`, metadataDraft(entry))
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
    const submission = {
      name: model.name.value,
      type: model.type.value,
      summary: model.summary.value,
      aliases: [...model.aliases.value],
      propertyDrafts: model.propertyDrafts.value.map(property => ({ ...property }))
    }
    applyOperations(operations, () => model.markSaved(submission))
  }

  if (detail.isLoading) {
    return (
      <PageStack className="mx-auto w-full max-w-4xl">
        <Skeleton className="h-16 w-2/3" />
        <Skeleton className="h-96 w-full" />
      </PageStack>
    )
  }

  if (detail.error || !entry) {
    return (
      <PageStack className="mx-auto w-full max-w-3xl">
        <PageHeader
          title={t('console.brain.entry_unavailable_title')}
          description={t('console.brain.entry_unavailable')}
        />
        <ErrorBlock
          title={t('console.brain.entry_unavailable_title')}
          error={detail.error ?? t('console.brain.entry_unavailable')}
          action={
            <Link
              className={cn(buttonVariants({ size: 'sm', variant: 'outline' }))}
              to={`/brain?${brainSearch(ownerUID)}`}>
              {t('console.brain.back_to_entries')}
            </Link>
          }
        />
      </PageStack>
    )
  }

  return (
    <ResourceEditorPage
      title={entry.name}
      description={`${entry.type} · ${entry.store_key} · ${t('console.brain.version', { count: entry.lock_version })}`}
      backTo={`/brain?${brainSearch(ownerUID, entry.store_key)}`}
      error={validationError ?? detail.error ?? apply.error ?? restore.error ?? deleteEntry.error}
      submitting={apply.isPending || deleteEntry.isPending}
      submitDisabled={!model.dirty.value}
      contentWidth="wide"
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
          </div>
        </TabsContent>
      </Tabs>
    </ResourceEditorPage>
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
            className="flex items-center gap-2 border border-border px-3 py-2 font-mono text-xs text-link hover:bg-muted">
            <RiExternalLinkLine />
            {documentID}
          </Link>
        ))}
      </CardContent>
    </Card>
  )
}
