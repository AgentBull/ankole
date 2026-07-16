import {
  Badge,
  Button,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton,
  TableCell,
  TableRow,
  Textarea,
  toast
} from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebBrainControllerCreateSourceMutation,
  ankoleWebBrainControllerLearnSourceMutation,
  ankoleWebBrainControllerSourceIndexOptions,
  ankoleWebBrainControllerSourceOptions,
  ankoleWebPrincipalControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import { ankoleWebBrainControllerSourceRaw } from '../api/generated/sdk.gen'
import type { BrainSourceEntry } from '../api/generated/types.gen'
import { ErrorBlock, formatJSON } from '../console-primitives'
import { LabeledField, ResourceEditorPage, ResourceListPage, RowActions } from '../console-shell'
import { defaultBrainOwnerUID, setBrainFilter } from '../state/brain-editor-model'
import {
  BrainOwnerField,
  BrainStoreField,
  BrainStoreName,
  BrainTaskNavigation,
  brainSearch,
  formatBrainDate
} from './brain-shared'

export function BrainSourcesPage() {
  const { t } = useTranslation()
  const [searchParams, setSearchParams] = useSearchParams()
  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const agents = (principals.data?.principals ?? []).filter(principal => principal.type === 'agent')
  const ownerUID = searchParams.get('owner') ?? defaultBrainOwnerUID(agents)
  const sources = useQuery({
    ...ankoleWebBrainControllerSourceIndexOptions({ query: { owner_uid: ownerUID } }),
    enabled: Boolean(ownerUID)
  })

  useEffect(() => {
    if (searchParams.has('owner') || !ownerUID) return
    const next = new URLSearchParams(searchParams)
    next.set('owner', ownerUID)
    setSearchParams(next, { replace: true })
  }, [ownerUID, searchParams, setSearchParams])

  const rows = sources.data?.sources ?? []

  return (
    <ResourceListPage
      title={t('console.brain.sources_title')}
      description={t('console.brain.sources_description')}
      columns={[
        t('console.brain.source_name'),
        t('console.brain.source_kind'),
        t('console.brain.store'),
        t('console.brain.learning_status'),
        t('console.brain.captured_at')
      ]}
      createLabel={t('console.brain.learn_source')}
      createTo={`/brain/learn?${brainSearch(ownerUID, searchParams.get('store') || 'public')}`}
      isLoading={sources.isLoading || principals.isLoading}
      isEmpty={rows.length === 0}
      emptyTitle={t('console.brain.sources_empty_title')}
      emptyDescription={t('console.brain.sources_empty_description')}
      error={sources.error ?? principals.error}
      toolbar={
        <div className="grid gap-4">
          <BrainTaskNavigation active="sources" ownerUID={ownerUID} />
          <div className="border border-border bg-card p-4">
            <BrainOwnerField
              ownerUID={ownerUID}
              principals={agents}
              onChange={value => setSearchParams(setBrainFilter(searchParams, 'owner', value), { replace: true })}
            />
          </div>
        </div>
      }>
      {rows.map(source => (
        <TableRow key={source.document_id}>
          <TableCell className="font-medium">
            <Link
              to={`/brain/sources/${encodeURIComponent(source.document_id)}?owner=${encodeURIComponent(ownerUID)}`}
              className="text-primary hover:underline">
              {source.title}
            </Link>
          </TableCell>
          <TableCell>
            <Badge variant="secondary">{sourceCaptureLabel(t, source)}</Badge>
          </TableCell>
          <TableCell className="text-xs">
            <BrainStoreName store={source.store_key} principals={principals.data?.principals ?? []} />
          </TableCell>
          <TableCell>
            <Badge variant={sourceStatusVariant(source.learning_status)}>
              {sourceStatusLabel(t, source.learning_status)}
            </Badge>
          </TableCell>
          <TableCell className="whitespace-nowrap text-xs text-muted-foreground">
            {formatBrainDate(source.captured_at)}
          </TableCell>
          <RowActions
            editLabel={t('common.open')}
            editTo={`/brain/sources/${encodeURIComponent(source.document_id)}?owner=${encodeURIComponent(ownerUID)}`}
          />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

export function BrainSourceLearnPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const allPrincipals = principals.data?.principals ?? []
  const agents = allPrincipals.filter(principal => principal.type === 'agent')
  const ownerUID = searchParams.get('owner') ?? defaultBrainOwnerUID(agents)
  const [store, setStore] = useState(searchParams.get('store') || 'public')
  const [kind, setKind] = useState<'url' | 'file' | 'paste'>('url')
  const [title, setTitle] = useState('')
  const [url, setURL] = useState('')
  const [content, setContent] = useState('')
  const [file, setFile] = useState<File>()
  const [validationError, setValidationError] = useState<string>()
  const create = useMutation(ankoleWebBrainControllerCreateSourceMutation())
  const learn = useMutation(ankoleWebBrainControllerLearnSourceMutation())

  useEffect(() => {
    if (searchParams.has('owner') || !ownerUID) return
    const next = new URLSearchParams(searchParams)
    next.set('owner', ownerUID)
    setSearchParams(next, { replace: true })
  }, [ownerUID, searchParams, setSearchParams])

  const submit = async () => {
    setValidationError(undefined)
    if (
      !ownerUID ||
      !store ||
      (kind === 'url' && !url.trim()) ||
      (kind === 'file' && !file) ||
      (kind === 'paste' && (!title.trim() || !content.trim()))
    ) {
      setValidationError(t('console.brain.source_required'))
      return
    }

    const body =
      kind === 'url'
        ? { kind, url: url.trim(), title: title.trim() || undefined }
        : kind === 'file'
          ? { kind, file: file!, title: title.trim() || undefined }
          : { kind, title: title.trim(), content }

    let documentID: string | undefined
    try {
      const captured = await create.mutateAsync({ query: { owner_uid: ownerUID, store }, body })
      documentID = captured.source.document_id
      await learn.mutateAsync({ path: { document_id: documentID }, query: { owner_uid: ownerUID } })
      toast.success(t('console.brain.source_queued'))
    } catch (error) {
      if (!documentID) {
        toast.error(requestErrorMessage(error))
        return
      }
      toast.info(t('console.brain.source_saved_retry'))
    }

    void queryClient.invalidateQueries()
    navigate(`/brain/sources/${encodeURIComponent(documentID)}?owner=${encodeURIComponent(ownerUID)}`)
  }

  const changeOwner = (value: string) => {
    setSearchParams(setBrainFilter(searchParams, 'owner', value), { replace: true })
    if (store === `dm:${value}`) setStore('public')
  }

  return (
    <ResourceEditorPage
      title={t('console.brain.learn_source')}
      description={t('console.brain.learn_source_description')}
      backTo={`/brain/sources?${brainSearch(ownerUID)}`}
      error={validationError ?? create.error ?? learn.error ?? principals.error}
      submitting={create.isPending || learn.isPending}
      submitLabel={t('console.brain.save_and_learn')}
      onSubmit={() => void submit()}>
      <BrainTaskNavigation active="sources" ownerUID={ownerUID} store={store} />
      <BrainOwnerField ownerUID={ownerUID} principals={agents} onChange={changeOwner} />
      <BrainStoreField ownerUID={ownerUID} store={store} principals={allPrincipals} onChange={setStore} />
      <LabeledField label={t('console.brain.source_kind')}>
        <Select value={kind} onValueChange={value => setKind(value as 'url' | 'file' | 'paste')}>
          <SelectTrigger>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="url">{t('console.brain.source_kind_url')}</SelectItem>
            <SelectItem value="file">{t('console.brain.source_kind_file')}</SelectItem>
            <SelectItem value="paste">{t('console.brain.source_kind_paste')}</SelectItem>
          </SelectContent>
        </Select>
      </LabeledField>
      <LabeledField label={t('console.brain.source_name')} description={t('console.brain.source_name_hint')}>
        <Input value={title} onChange={event => setTitle(event.target.value)} />
      </LabeledField>
      {kind === 'url' ? (
        <LabeledField label="URL">
          <Input type="url" value={url} onChange={event => setURL(event.target.value)} />
        </LabeledField>
      ) : null}
      {kind === 'file' ? (
        <LabeledField label={t('console.brain.source_file')}>
          <Input type="file" onChange={event => setFile(event.target.files?.[0])} />
        </LabeledField>
      ) : null}
      {kind === 'paste' ? (
        <LabeledField label={t('console.brain.source_content')}>
          <Textarea className="min-h-64" value={content} onChange={event => setContent(event.target.value)} />
        </LabeledField>
      ) : null}
    </ResourceEditorPage>
  )
}

export function BrainSourcePage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const params = useParams()
  const [searchParams] = useSearchParams()
  const documentID = params.documentID ?? ''
  const ownerUID = searchParams.get('owner') ?? ''
  const entryID = searchParams.get('entry') ?? ''
  const [downloading, setDownloading] = useState(false)
  const source = useQuery({
    ...ankoleWebBrainControllerSourceOptions({
      path: { document_id: documentID },
      query: { owner_uid: ownerUID }
    }),
    enabled: Boolean(documentID && ownerUID),
    retry: false
  })
  const retry = useMutation({
    ...ankoleWebBrainControllerLearnSourceMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.source_queued'))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const item = source.data?.source

  const download = async () => {
    if (!item || item.kind !== 'retained_source') return
    setDownloading(true)
    try {
      const response = await ankoleWebBrainControllerSourceRaw({
        path: { document_id: documentID },
        query: { owner_uid: ownerUID },
        throwOnError: true
      })
      const objectURL = URL.createObjectURL(response.data)
      const anchor = document.createElement('a')
      anchor.href = objectURL
      anchor.download = item.original_name || item.title
      anchor.click()
      URL.revokeObjectURL(objectURL)
    } catch (error) {
      toast.error(requestErrorMessage(error))
    } finally {
      setDownloading(false)
    }
  }

  const backTo = entryID
    ? `/brain/${entryID}?${brainSearch(ownerUID)}`
    : item?.kind === 'signal_message'
      ? `/brain?${brainSearch(ownerUID, item.store_key)}`
      : `/brain/sources?${brainSearch(ownerUID)}`

  return (
    <div className="mx-auto grid max-w-4xl gap-5">
      <Link to={backTo} className="w-fit text-sm text-muted-foreground hover:text-foreground">
        ← {t('common.back')}
      </Link>
      <BrainTaskNavigation active="sources" ownerUID={ownerUID} store={item?.store_key} />
      <div>
        <h2 className="text-2xl font-semibold">{item?.title || t('console.brain.source_title')}</h2>
        <p className="break-all font-mono text-xs text-muted-foreground">{documentID}</p>
      </div>
      <ErrorBlock error={source.error ?? retry.error} />
      {source.isLoading ? (
        <Skeleton className="h-72 w-full" />
      ) : item ? (
        <Card>
          <CardHeader>
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div>
                <CardTitle>{item.kind === 'signal_message' ? sourceAuthor(item.author) : item.title}</CardTitle>
                <CardDescription>
                  <BrainStoreName store={item.store_key} principals={[]} /> · {formatBrainDate(item.captured_at)}
                </CardDescription>
              </div>
              <div className="flex flex-wrap gap-2">
                <Badge variant="secondary">{sourceCaptureLabel(t, item)}</Badge>
                {item.learning_status ? (
                  <Badge variant={sourceStatusVariant(item.learning_status)}>
                    {sourceStatusLabel(t, item.learning_status)}
                  </Badge>
                ) : null}
              </div>
            </div>
          </CardHeader>
          <CardContent className="grid gap-4">
            <p className="whitespace-pre-wrap text-sm leading-6">{item.text || '—'}</p>
            {item.kind === 'retained_source' ? (
              <div className="flex flex-wrap gap-2">
                <Button type="button" size="sm" variant="outline" disabled={downloading} onClick={download}>
                  {t('console.brain.download_source')}
                </Button>
                {canRetryLearning(item.learning_status) ? (
                  <Button
                    type="button"
                    size="sm"
                    disabled={retry.isPending}
                    onClick={() =>
                      retry.mutate({
                        path: { document_id: documentID },
                        query: { owner_uid: ownerUID }
                      })
                    }>
                    {t('console.brain.retry_learning')}
                  </Button>
                ) : null}
              </div>
            ) : null}
            <SourceIntegrationLinks item={item} ownerUID={ownerUID} />
            <details>
              <summary className="cursor-pointer text-sm text-muted-foreground">
                {t('console.brain.source_metadata')}
              </summary>
              <pre className="mt-2 max-h-80 overflow-auto whitespace-pre-wrap break-all bg-muted p-3 text-xs">
                {formatJSON({
                  kind: item.kind,
                  capture_method: item.capture_method,
                  origin_locator: item.origin_locator,
                  original_name: item.original_name,
                  media_type: item.media_type,
                  byte_size: item.byte_size,
                  sha256: item.sha256,
                  captured_by_uid: item.captured_by_uid,
                  learning_actor_event_id: item.learning_actor_event_id,
                  signal_channel_id: item.signal_channel_id,
                  source_entry_id: item.source_entry_id,
                  rich_content: item.rich_content,
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

function SourceIntegrationLinks({ item, ownerUID }: { item: BrainSourceEntry; ownerUID: string }) {
  const { t } = useTranslation()
  if (item.integrated_entries.length === 0) {
    return <p className="text-sm text-muted-foreground">{t('console.brain.source_not_integrated')}</p>
  }

  return (
    <section className="grid gap-2">
      <h3 className="text-sm font-medium">{t('console.brain.integrated_entries')}</h3>
      {item.integrated_entries.map(entry => (
        <Link
          key={entry.id}
          to={`/brain/${entry.id}?${brainSearch(ownerUID, entry.store_key)}`}
          className="border border-border px-3 py-2 text-sm text-primary hover:bg-muted">
          {entry.name}
        </Link>
      ))}
    </section>
  )
}

function sourceCaptureLabel(t: ReturnType<typeof useTranslation>['t'], source: BrainSourceEntry): string {
  if (source.kind === 'signal_message') return t('console.brain.source_kind_signal')
  return t(`console.brain.source_kind_${source.capture_method ?? 'file'}`)
}

function sourceStatusLabel(
  t: ReturnType<typeof useTranslation>['t'],
  status?: BrainSourceEntry['learning_status']
): string {
  return t(`console.brain.learning_status_${status ?? 'stored'}`)
}

function sourceStatusVariant(
  status?: BrainSourceEntry['learning_status']
): 'secondary' | 'outline' | 'success' | 'warning' | 'destructive' {
  if (status === 'integrated' || status === 'no_change') return 'success'
  if (status === 'incomplete') return 'warning'
  if (status === 'failed') return 'destructive'
  if (status === 'learning') return 'outline'
  return 'secondary'
}

function canRetryLearning(status?: BrainSourceEntry['learning_status']): boolean {
  return status === 'stored' || status === 'no_change' || status === 'incomplete' || status === 'failed'
}

function sourceAuthor(author?: Record<string, unknown>): string {
  if (!author) return '—'
  for (const key of ['display_name', 'name', 'principal_uid', 'id']) {
    if (typeof author[key] === 'string' && author[key]) return String(author[key])
  }
  return '—'
}
