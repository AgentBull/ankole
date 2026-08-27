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
import { RiScales3Line, RiLoaderLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebBrainControllerDecideContradictionMutation,
  ankoleWebBrainControllerListContradictionsOptions,
  ankoleWebBrainControllerListContradictionsQueryKey
} from '../../api/generated/@tanstack/react-query.gen'
import type { BrainContradiction } from '../../api/generated/types.gen'
import { requestErrorMessage } from '../../../common/request-errors'
import { formatConsoleDate } from '../../console-primitives'
import { ResourceListPage } from '../../console-list-page'
import { BrainSubNav } from './brain-nav'

const CONTRADICTION_STATUSES = ['open', 'resolved', 'dismissed'] as const

export function BrainContradictionsPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [status, setStatus] = useState<(typeof CONTRADICTION_STATUSES)[number]>('open')
  const [decideTarget, setDecideTarget] = useState<{
    contradiction: BrainContradiction
    decision: 'resolved' | 'dismissed'
  }>()
  const [note, setNote] = useState('')

  const contradictions = useQuery(ankoleWebBrainControllerListContradictionsOptions({ query: { status } }))
  const rows = contradictions.data?.contradictions ?? []

  // Reset per target so a note typed for one contradiction never carries to another.
  const openDecide = (contradiction: BrainContradiction, decision: 'resolved' | 'dismissed') => {
    setDecideTarget({ contradiction, decision })
    setNote('')
  }
  const decide = useMutation({
    ...ankoleWebBrainControllerDecideContradictionMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.contradiction_decided'))
      setDecideTarget(undefined)
      void queryClient.invalidateQueries({ queryKey: ankoleWebBrainControllerListContradictionsQueryKey() })
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <>
      <ResourceListPage
        title={t('console.brain.contradictions_title')}
        description={t('console.brain.contradictions_description')}
        subNav={<BrainSubNav />}
        columns={[
          t('console.brain.claim_pair'),
          t('console.brain.verdict'),
          t('console.brain.severity'),
          t('console.brain.confidence'),
          t('console.brain.created')
        ]}
        isLoading={contradictions.isLoading}
        isEmpty={rows.length === 0}
        count={rows.length}
        emptyTitle={t('console.brain.contradictions_empty_title')}
        emptyDescription={t('console.brain.contradictions_empty_description')}
        emptyIcon={<RiScales3Line aria-hidden />}
        error={contradictions.error}
        isFiltered={status !== 'open'}
        onClearFilters={() => setStatus('open')}
        toolbarCanRevealRows
        toolbar={
          <div className="flex items-center gap-3 border border-border bg-card p-2">
            <Select
              value={status}
              onValueChange={value => {
                if (typeof value === 'string' && (CONTRADICTION_STATUSES as readonly string[]).includes(value)) {
                  setStatus(value as (typeof CONTRADICTION_STATUSES)[number])
                }
              }}>
              <SelectTrigger aria-label={t('console.brain.state')} size="sm">
                <SelectValue>{value => t(`console.brain.contradiction_status_${String(value)}`)}</SelectValue>
              </SelectTrigger>
              <SelectContent>
                {CONTRADICTION_STATUSES.map(option => (
                  <SelectItem key={option} value={option}>
                    {t(`console.brain.contradiction_status_${option}`)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        }>
        {rows.map(contradiction => (
          <TableRow key={contradiction.id}>
            <TableCell className="max-w-[420px] whitespace-normal">
              <div className="grid gap-1.5 text-xs">
                <p>
                  <Badge className="mr-2" variant="secondary">
                    A
                  </Badge>
                  {contradiction.a_claim?.claim ?? '—'}
                </p>
                <p>
                  <Badge className="mr-2" variant="outline">
                    B
                  </Badge>
                  {contradiction.b_claim?.claim ?? '—'}
                </p>
              </div>
            </TableCell>
            <TableCell className="text-xs">
              {contradiction.verdict ?? '—'}
              {contradiction.axis ? ` · ${contradiction.axis}` : ''}
            </TableCell>
            <TableCell className="text-xs">{contradiction.severity ?? '—'}</TableCell>
            <TableCell className="text-xs">{contradiction.confidence ?? '—'}</TableCell>
            <TableCell className="text-xs text-muted-foreground">
              {formatConsoleDate(contradiction.created_at)}
            </TableCell>
            <TableCell className="text-right">
              {status === 'open' ? (
                <div className="flex justify-end gap-1">
                  <Button size="xs" type="button" variant="ghost" onClick={() => openDecide(contradiction, 'resolved')}>
                    {t('console.brain.resolve')}
                  </Button>
                  <Button
                    size="xs"
                    type="button"
                    variant="ghost"
                    onClick={() => openDecide(contradiction, 'dismissed')}>
                    {t('console.brain.dismiss')}
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
        open={Boolean(decideTarget)}
        onOpenChange={open => !decide.isPending && !open && setDecideTarget(undefined)}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!decide.isPending}>
          <DialogHeader>
            <DialogTitle>
              {decideTarget?.decision === 'resolved'
                ? t('console.brain.contradiction_resolve_title')
                : t('console.brain.contradiction_dismiss_title')}
            </DialogTitle>
            <DialogDescription>{t('console.brain.contradiction_decide_description')}</DialogDescription>
          </DialogHeader>
          <Input
            aria-label={t('console.brain.resolution_note')}
            placeholder={t('console.brain.resolution_note')}
            value={note}
            onChange={event => setNote(event.target.value)}
          />
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={decide.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={decide.isPending}
              onClick={() =>
                decideTarget &&
                decide.mutate({
                  path: { ['contradiction_id']: decideTarget.contradiction.id },
                  body: {
                    status: decideTarget.decision,
                    ...(note.trim() ? { ['resolution_note']: note.trim() } : {})
                  }
                })
              }>
              {decide.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {decideTarget?.decision === 'resolved' ? t('console.brain.resolve') : t('console.brain.dismiss')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
