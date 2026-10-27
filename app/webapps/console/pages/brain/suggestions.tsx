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
import { useMutation, useInfiniteQuery, useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  approveBrainSuggestionMutation,
  listBrainObjectTypesOptions,
  listBrainSuggestionsInfiniteOptions,
  rejectBrainSuggestionMutation
} from '../../api/v2/generated/@tanstack/react-query.gen'
import type { ListBrainSuggestionsResponse } from '../../api/v2/generated/types.gen'
import { nextPageParams, fromDocument, type Flat } from '../../api/json-api'
import { requestErrorMessage } from '../../../common/request-errors'
import { DiscardConfirmDialog, LabeledField, useDialogDiscardGuard } from '../../console-form'
import { formatConsoleDate } from '../../console-primitives'
import { ResourceListPage } from '../../console-list-page'
import { BrainSubNav } from './brain-nav'

const SUGGESTION_STATUSES = ['pending', 'approved', 'rejected'] as const
const BRAIN_PRIMITIVES = ['concept', 'entity', 'media', 'temporal', 'annotation'] as const

type BrainSuggestion = Flat<NonNullable<ListBrainSuggestionsResponse['data']>[number]>

export function BrainSuggestionsPage() {
  const { t } = useTranslation()
  const [status, setStatus] = useState<(typeof SUGGESTION_STATUSES)[number]>('pending')
  const [approveTarget, setApproveTarget] = useState<BrainSuggestion>()
  const [rejectTarget, setRejectTarget] = useState<BrainSuggestion>()
  const [primitive, setPrimitive] = useState('')
  const [slugPrefix, setSlugPrefix] = useState('')
  const [targetType, setTargetType] = useState('')

  const suggestions = useInfiniteQuery({
    ...listBrainSuggestionsInfiniteOptions({ query: { status } }),
    initialPageParam: {},
    getNextPageParam: nextPageParams,
    select: data => data.pages.flatMap(document => fromDocument(document))
  })
  const rows = suggestions.data ?? []

  const objectTypes = useQuery({
    ...listBrainObjectTypesOptions(),
    enabled: Boolean(approveTarget)
  })
  const selectableObjectTypes = Array.from(
    new Set([...(objectTypes.data?.types ?? []), ...(approveTarget?.target_type ? [approveTarget.target_type] : [])])
  )

  const approve = useMutation({
    ...approveBrainSuggestionMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.suggestion_approved'))
      setApproveTarget(undefined)
      setPrimitive('')
      setSlugPrefix('')
      setTargetType('')
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const approveGuard = useDialogDiscardGuard({
    dirty: Boolean(approveTarget) && Boolean(primitive || slugPrefix.trim() || targetType),
    onOpenChange: open => !open && setApproveTarget(undefined),
    pending: approve.isPending
  })
  const reject = useMutation({
    ...rejectBrainSuggestionMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.suggestion_rejected'))
      setRejectTarget(undefined)
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
        pagination={suggestions}
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
                  <Button
                    size="xs"
                    type="button"
                    variant="ghost"
                    onClick={() => {
                      setPrimitive('')
                      setSlugPrefix('')
                      setTargetType('')
                      setApproveTarget(suggestion)
                    }}>
                    {t('console.brain.approve')}
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

      <Dialog open={Boolean(approveTarget)} onOpenChange={approveGuard.requestOpenChange}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!approve.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.brain.approve_title', { term: approveTarget?.term ?? '' })}</DialogTitle>
            <DialogDescription>{t('console.brain.approve_description')}</DialogDescription>
          </DialogHeader>
          <div className="grid gap-4">
            <LabeledField label={t('console.brain.approve_primitive')}>
              <Select value={primitive} onValueChange={value => setPrimitive(value ?? '')}>
                <SelectTrigger aria-label={t('console.brain.approve_primitive')} className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="">
                    {t('console.brain.primitive_default', { defaultValue: 'Default (concept)' })}
                  </SelectItem>
                  {BRAIN_PRIMITIVES.map(item => (
                    <SelectItem key={item} value={item}>
                      {t(`console.brain.primitive_${item}`, { defaultValue: item })}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </LabeledField>
            <LabeledField label={t('console.brain.approve_slug_prefix')}>
              <Input
                className="font-mono"
                spellCheck={false}
                value={slugPrefix}
                onChange={event => setSlugPrefix(event.target.value)}
              />
            </LabeledField>
            <LabeledField label={t('console.brain.approve_target_type')}>
              <Select value={targetType} onValueChange={value => setTargetType(value ?? '')}>
                <SelectTrigger aria-label={t('console.brain.approve_target_type')} className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent emptyLabel={objectTypes.isLoading ? t('common.loading') : t('common.select_empty')}>
                  <SelectItem value="">
                    {approveTarget?.target_type
                      ? t('console.brain.target_type_suggested', {
                          defaultValue: 'Suggested ({$type})',
                          type: approveTarget.target_type
                        })
                      : t('console.brain.target_type_default', { defaultValue: 'Default (note)' })}
                  </SelectItem>
                  {selectableObjectTypes.map(typeName => (
                    <SelectItem key={typeName} value={typeName}>
                      {typeName}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </LabeledField>
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
                    data: {
                      ...(primitive.trim() ? { primitive: primitive.trim() } : {}),
                      ...(slugPrefix.trim() ? { slug_prefix: slugPrefix.trim() } : {}),
                      ...(targetType.trim() ? { target_type: targetType.trim() } : {})
                    }
                  }
                })
              }>
              {approve.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.brain.approve')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <DiscardConfirmDialog
        open={approveGuard.confirming}
        onDiscard={approveGuard.confirmDiscard}
        onKeep={approveGuard.keepEditing}
      />

      <Dialog
        open={Boolean(rejectTarget)}
        onOpenChange={open => !reject.isPending && !open && setRejectTarget(undefined)}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!reject.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.brain.reject_title', { term: rejectTarget?.term ?? '' })}</DialogTitle>
            <DialogDescription>{t('console.brain.reject_description')}</DialogDescription>
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
