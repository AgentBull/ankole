import {
  Badge,
  Button,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  TableCell,
  TableRow,
  toast
} from '@ankole/uikit'
import { RiGitMergeLine, RiLoaderLine } from '@remixicon/react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  approveBrainMergeSuggestionMutation,
  listBrainMergeSuggestionsOptions,
  rejectBrainMergeSuggestionMutation
} from '../../api/v2/generated/@tanstack/react-query.gen'
import type { ListBrainMergeSuggestionsResponse } from '../../api/v2/generated/types.gen'
import { fromDocument, type Flat } from '../../api/json-api'
import { requestErrorMessage } from '../../../common/request-errors'
import { formatConsoleDate } from '../../console-primitives'
import { ResourceListPage } from '../../console-list-page'
import { BrainSubNav } from './brain-nav'

const SUGGESTION_STATUSES = ['pending', 'approved', 'rejected'] as const

type BrainMergeSuggestion = Flat<NonNullable<ListBrainMergeSuggestionsResponse['data']>[number]>
// The server always gives both summaries; the OpenAPI document types each
// calculation as nullable.
type BrainMergePageSummary = NonNullable<BrainMergeSuggestion['a_page']>

function PageCell({ page }: { page?: BrainMergePageSummary | null }) {
  if (!page) return <span className="text-xs">—</span>
  return (
    <div className="grid gap-0.5">
      <span className="text-xs">{page.title ?? page.slug}</span>
      <span className="font-mono text-[11px] text-muted-foreground">{page.slug}</span>
    </div>
  )
}

export function BrainMergeSuggestionsPage() {
  const { t } = useTranslation()
  const [status, setStatus] = useState<(typeof SUGGESTION_STATUSES)[number]>('pending')
  const [approveTarget, setApproveTarget] = useState<BrainMergeSuggestion>()
  const [rejectTarget, setRejectTarget] = useState<BrainMergeSuggestion>()
  const [canonicalSlug, setCanonicalSlug] = useState('')

  const suggestions = useQuery({
    ...listBrainMergeSuggestionsOptions({ query: { status } }),
    select: document => fromDocument(document)
  })
  const rows = suggestions.data ?? []

  const approve = useMutation({
    ...approveBrainMergeSuggestionMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.merge_approved'))
      setApproveTarget(undefined)
      setCanonicalSlug('')
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const reject = useMutation({
    ...rejectBrainMergeSuggestionMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.merge_rejected'))
      setRejectTarget(undefined)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <>
      <ResourceListPage
        title={t('console.brain.merge_suggestions_title')}
        description={t('console.brain.merge_suggestions_description')}
        subNav={<BrainSubNav />}
        columns={[
          t('console.brain.merge_page_a'),
          t('console.brain.merge_page_b'),
          t('console.brain.type'),
          t('console.brain.merge_reason'),
          t('console.brain.created')
        ]}
        isLoading={suggestions.isLoading}
        isEmpty={rows.length === 0}
        count={rows.length}
        emptyTitle={t('console.brain.merge_suggestions_empty_title')}
        emptyDescription={t('console.brain.merge_suggestions_empty_description')}
        emptyIcon={<RiGitMergeLine aria-hidden />}
        error={suggestions.error}
        isFiltered={status !== 'pending'}
        onClearFilters={() => setStatus('pending')}
        toolbarCanRevealRows
        toolbar={
          <div className="flex items-center gap-3 border border-border bg-card p-2">
            <Select
              value={status}
              onValueChange={value => {
                if (typeof value === 'string' && (SUGGESTION_STATUSES as readonly string[]).includes(value)) {
                  setStatus(value as (typeof SUGGESTION_STATUSES)[number])
                }
              }}>
              <SelectTrigger aria-label={t('console.brain.state')} size="sm">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {SUGGESTION_STATUSES.map(option => (
                  <SelectItem key={option} value={option}>
                    {t(`console.brain.suggestion_status_${option}`)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        }>
        {rows.map(suggestion => (
          <TableRow key={suggestion.id}>
            <TableCell>
              <PageCell page={suggestion.a_page} />
            </TableCell>
            <TableCell>
              <PageCell page={suggestion.b_page} />
            </TableCell>
            <TableCell>
              <Badge variant="secondary">{suggestion.a_page?.type ?? suggestion.b_page?.type ?? '—'}</Badge>
            </TableCell>
            <TableCell className="max-w-[280px] whitespace-normal text-xs text-muted-foreground">
              {suggestion.reason}
            </TableCell>
            <TableCell className="text-xs text-muted-foreground">{formatConsoleDate(suggestion.created_at)}</TableCell>
            <TableCell className="text-right">
              {status === 'pending' ? (
                <div className="flex justify-end gap-1">
                  <Button
                    size="xs"
                    type="button"
                    variant="ghost"
                    onClick={() => {
                      setCanonicalSlug(suggestion.a_page?.slug ?? '')
                      setApproveTarget(suggestion)
                    }}>
                    {t('console.brain.merge_action')}
                  </Button>
                  <Button size="xs" type="button" variant="ghost" onClick={() => setRejectTarget(suggestion)}>
                    {t('console.brain.reject')}
                  </Button>
                </div>
              ) : (
                <span className="pr-2 text-xs text-muted-foreground">{t('console.brain.read_only')}</span>
              )}
            </TableCell>
          </TableRow>
        ))}
      </ResourceListPage>

      <Dialog
        open={Boolean(approveTarget)}
        onOpenChange={open => !approve.isPending && !open && setApproveTarget(undefined)}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!approve.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.brain.merge_approve_title')}</DialogTitle>
            <DialogDescription>{t('console.brain.merge_approve_description')}</DialogDescription>
          </DialogHeader>
          <label className="grid gap-1.5 text-xs text-muted-foreground">
            {t('console.brain.merge_canonical')}
            <Select value={canonicalSlug} onValueChange={value => typeof value === 'string' && setCanonicalSlug(value)}>
              <SelectTrigger aria-label={t('console.brain.merge_canonical')}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {[approveTarget?.a_page, approveTarget?.b_page]
                  .filter((page): page is BrainMergePageSummary => Boolean(page))
                  .map(page => (
                    <SelectItem key={page.slug} value={page.slug}>
                      {page.title ? `${page.title} (${page.slug})` : page.slug}
                    </SelectItem>
                  ))}
              </SelectContent>
            </Select>
          </label>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={approve.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={approve.isPending || !canonicalSlug}
              onClick={() =>
                approveTarget &&
                approve.mutate({
                  path: { suggestion_id: approveTarget.id },
                  body: { data: { canonical_slug: canonicalSlug } }
                })
              }>
              {approve.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.brain.merge_action')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog
        open={Boolean(rejectTarget)}
        onOpenChange={open => !reject.isPending && !open && setRejectTarget(undefined)}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!reject.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.brain.merge_reject_title')}</DialogTitle>
            <DialogDescription>{t('console.brain.merge_reject_description')}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={reject.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={reject.isPending}
              variant="destructive"
              onClick={() => rejectTarget && reject.mutate({ path: { suggestion_id: rejectTarget.id } })}>
              {reject.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.brain.reject')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
