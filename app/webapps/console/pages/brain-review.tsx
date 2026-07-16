import { Badge, Button, Card, CardContent, CardDescription, CardHeader, CardTitle, Skeleton } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useSearchParams } from 'react-router'
import {
  ankoleWebBrainControllerReviewCandidatesOptions,
  ankoleWebPrincipalControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { BrainReviewCandidatesResponse, JsonValue as JSONValue } from '../api/generated/types.gen'
import { ErrorBlock, formatJSON } from '../console-primitives'
import { PageHeader } from '../console-shell'
import { defaultBrainOwnerUID, setBrainFilter } from '../state/brain-editor-model'
import { BrainOwnerField, BrainTaskNavigation, brainSearch } from './brain-shared'

type Review = BrainReviewCandidatesResponse['review']
type ReviewBucketKey = Exclude<keyof Review, 'status' | 'checked_entry_count'>

const REVIEW_BUCKETS: ReviewBucketKey[] = [
  'broken_citations',
  'uncited_generated_blocks',
  'stale_entries',
  'unintegrated_sources',
  'old_url_sources',
  'orphan_entries',
  'long_entries',
  'failed_embeddings',
  'over_budget_pinned_memos',
  'dreaming_blocks'
]

export function BrainReviewPage() {
  const { t } = useTranslation()
  const [searchParams, setSearchParams] = useSearchParams()
  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const ownerUID = searchParams.get('owner') ?? defaultBrainOwnerUID(principals.data?.principals ?? [])
  const candidates = useQuery({
    ...ankoleWebBrainControllerReviewCandidatesOptions({ query: { owner_uid: ownerUID } }),
    enabled: Boolean(ownerUID)
  })

  useEffect(() => {
    if (searchParams.has('owner') || !ownerUID) return
    const next = new URLSearchParams(searchParams)
    next.set('owner', ownerUID)
    setSearchParams(next, { replace: true })
  }, [ownerUID, searchParams, setSearchParams])

  const review = candidates.data?.review
  const candidateCount = review ? REVIEW_BUCKETS.reduce((count, key) => count + review[key].length, 0) : 0

  return (
    <div className="grid gap-5">
      <PageHeader title={t('console.brain.review_title')} description={t('console.brain.review_description')} />
      <BrainTaskNavigation active="review" ownerUID={ownerUID} />
      <div className="grid gap-4 border border-border bg-card p-4 md:grid-cols-2">
        <BrainOwnerField
          ownerUID={ownerUID}
          principals={principals.data?.principals ?? []}
          onChange={value => setSearchParams(setBrainFilter(searchParams, 'owner', value), { replace: true })}
        />
        <div className="grid content-center gap-1 text-sm text-muted-foreground">
          <span>{t('console.brain.review_checked', { count: review?.checked_entry_count ?? 0 })}</span>
          <span>{t('console.brain.review_found', { count: candidateCount })}</span>
        </div>
      </div>
      <ErrorBlock error={candidates.error ?? principals.error} />
      {candidates.isLoading || principals.isLoading ? (
        <div className="grid gap-4 lg:grid-cols-2">
          <Skeleton className="h-48" />
          <Skeleton className="h-48" />
        </div>
      ) : review ? (
        <div className="grid items-start gap-4 lg:grid-cols-2">
          {REVIEW_BUCKETS.map(key => (
            <ReviewBucket key={key} bucketKey={key} items={review[key]} ownerUID={ownerUID} />
          ))}
        </div>
      ) : null}
    </div>
  )
}

function ReviewBucket({
  bucketKey,
  items,
  ownerUID
}: {
  bucketKey: ReviewBucketKey
  items: JSONValue[]
  ownerUID: string
}) {
  const { t } = useTranslation()

  return (
    <Card>
      <CardHeader>
        <div className="flex items-start justify-between gap-3">
          <div className="grid gap-1">
            <CardTitle>{t(`console.brain.review_${bucketKey}`)}</CardTitle>
            <CardDescription>{t(`console.brain.review_${bucketKey}_description`)}</CardDescription>
          </div>
          <Badge variant={items.length > 0 ? 'warning' : 'secondary'}>{items.length}</Badge>
        </div>
      </CardHeader>
      <CardContent className="grid gap-2">
        {items.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t('console.brain.review_none')}</p>
        ) : (
          items.map((item, index) => (
            <ReviewCandidate key={candidateKey(item, index)} item={item} ownerUID={ownerUID} />
          ))
        )}
      </CardContent>
    </Card>
  )
}

function ReviewCandidate({ item, ownerUID }: { item: JSONValue; ownerUID: string }) {
  const { t } = useTranslation()
  const value = jsonObject(item)
  const entryID = textValue(value?.entry_id)
  const documentID = textValue(value?.document_id)
  const label =
    textValue(value?.entry_name) ||
    textValue(value?.name) ||
    textValue(value?.title) ||
    documentID ||
    textValue(value?.reason) ||
    t('common.open')
  const to = entryID
    ? `/brain/${entryID}?${brainSearch(ownerUID, textValue(value?.store_key) || textValue(value?.store))}`
    : documentID
      ? `/brain/sources/${encodeURIComponent(documentID)}?owner=${encodeURIComponent(ownerUID)}`
      : undefined

  return (
    <div className="grid gap-2 border border-border p-3">
      <div className="flex min-w-0 items-start justify-between gap-3">
        <span className="min-w-0 break-words text-sm font-medium">{label}</span>
        {to ? (
          <Button render={<Link to={to} />} size="xs" variant="outline">
            {t('common.open')}
          </Button>
        ) : null}
      </div>
      <pre className="max-h-40 overflow-auto whitespace-pre-wrap break-all text-xs text-muted-foreground">
        {formatJSON(item)}
      </pre>
    </div>
  )
}

function jsonObject(value: JSONValue): Record<string, JSONValue> | undefined {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, JSONValue>) : undefined
}

function textValue(value: JSONValue | undefined): string | undefined {
  return typeof value === 'string' && value ? value : undefined
}

function candidateKey(item: JSONValue, index: number): string {
  const value = jsonObject(item)
  return (
    textValue(value?.block_id) ||
    textValue(value?.entry_id) ||
    textValue(value?.document_id) ||
    `${index}:${JSON.stringify(item)}`
  )
}
