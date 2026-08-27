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
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  TableCell,
  TableRow,
  toast
} from '@ankole/uikit'
import { RiLightbulbLine, RiLoaderLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebBrainControllerDecideSuggestionMutation,
  ankoleWebBrainControllerListSuggestionsOptions,
  ankoleWebBrainControllerListSuggestionsQueryKey
} from '../../api/generated/@tanstack/react-query.gen'
import type { BrainSuggestion } from '../../api/generated/types.gen'
import { requestErrorMessage } from '../../../common/request-errors'
import { formatConsoleDate } from '../../console-primitives'
import { ResourceListPage } from '../../console-list-page'
import { BrainSubNav } from './brain-nav'

const SUGGESTION_STATUSES = ['pending', 'approved', 'rejected'] as const

export function BrainSuggestionsPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [status, setStatus] = useState<(typeof SUGGESTION_STATUSES)[number]>('pending')
  const [approveTarget, setApproveTarget] = useState<BrainSuggestion>()
  const [primitive, setPrimitive] = useState('')
  const [slugPrefix, setSlugPrefix] = useState('')
  const [targetType, setTargetType] = useState('')

  const suggestions = useQuery(ankoleWebBrainControllerListSuggestionsOptions({ query: { status } }))
  const rows = suggestions.data?.suggestions ?? []
  const invalidate = () =>
    void queryClient.invalidateQueries({ queryKey: ankoleWebBrainControllerListSuggestionsQueryKey() })

  const approve = useMutation({
    ...ankoleWebBrainControllerDecideSuggestionMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.suggestion_approved'))
      setApproveTarget(undefined)
      setPrimitive('')
      setSlugPrefix('')
      setTargetType('')
      invalidate()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const reject = useMutation({
    ...ankoleWebBrainControllerDecideSuggestionMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.suggestion_rejected'))
      invalidate()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <>
      <ResourceListPage
        title={t('console.brain.suggestions_title')}
        description={t('console.brain.suggestions_description')}
        subNav={<BrainSubNav />}
        columns={[
          t('console.brain.term'),
          t('console.brain.kind'),
          t('console.brain.target_type'),
          t('console.brain.evidence'),
          t('console.brain.rationale'),
          t('console.brain.created')
        ]}
        isLoading={suggestions.isLoading}
        isEmpty={rows.length === 0}
        count={rows.length}
        emptyTitle={t('console.brain.suggestions_empty_title')}
        emptyDescription={t('console.brain.suggestions_empty_description')}
        emptyIcon={<RiLightbulbLine aria-hidden />}
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
                <SelectValue>{value => t(`console.brain.suggestion_status_${String(value)}`)}</SelectValue>
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
            <TableCell className="font-mono text-xs">{suggestion.term}</TableCell>
            <TableCell>
              <Badge variant="secondary">{suggestion.kind}</Badge>
            </TableCell>
            <TableCell className="text-xs">{suggestion.target_type ?? '—'}</TableCell>
            <TableCell className="text-xs">{suggestion.evidence_count}</TableCell>
            <TableCell className="max-w-[320px] whitespace-normal text-xs text-muted-foreground">
              {suggestion.rationale ?? '—'}
            </TableCell>
            <TableCell className="text-xs text-muted-foreground">{formatConsoleDate(suggestion.created_at)}</TableCell>
            <TableCell className="text-right">
              {status === 'pending' ? (
                <div className="flex justify-end gap-1">
                  <Button size="xs" type="button" variant="ghost" onClick={() => setApproveTarget(suggestion)}>
                    {t('console.brain.approve')}
                  </Button>
                  <Button
                    disabled={reject.isPending}
                    size="xs"
                    type="button"
                    variant="ghost"
                    onClick={() =>
                      reject.mutate({
                        path: { suggestion_id: suggestion.id },
                        body: { decision: 'reject' }
                      })
                    }>
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
            <DialogTitle>{t('console.brain.approve_title', { term: approveTarget?.term ?? '' })}</DialogTitle>
            <DialogDescription>{t('console.brain.approve_description')}</DialogDescription>
          </DialogHeader>
          <div className="grid gap-4">
            <label className="grid gap-1.5 text-xs text-muted-foreground">
              {t('console.brain.approve_primitive')}
              <Input
                placeholder={approveTarget?.kind ?? ''}
                value={primitive}
                onChange={event => setPrimitive(event.target.value)}
              />
            </label>
            <label className="grid gap-1.5 text-xs text-muted-foreground">
              {t('console.brain.approve_slug_prefix')}
              <Input
                className="font-mono"
                spellCheck={false}
                value={slugPrefix}
                onChange={event => setSlugPrefix(event.target.value)}
              />
            </label>
            <label className="grid gap-1.5 text-xs text-muted-foreground">
              {t('console.brain.approve_target_type')}
              <Input
                placeholder={approveTarget?.target_type ?? ''}
                value={targetType}
                onChange={event => setTargetType(event.target.value)}
              />
            </label>
          </div>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={approve.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={approve.isPending}
              onClick={() =>
                approveTarget &&
                approve.mutate({
                  path: { suggestion_id: approveTarget.id },
                  body: {
                    decision: 'approve',
                    ...(primitive.trim() ? { primitive: primitive.trim() } : {}),
                    ...(slugPrefix.trim() ? { slug_prefix: slugPrefix.trim() } : {}),
                    ...(targetType.trim() ? { target_type: targetType.trim() } : {})
                  }
                })
              }>
              {approve.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.brain.approve')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
