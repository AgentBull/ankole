import { TableRow, useMutation, useInfiniteQuery, useQuery, Link } from '../../tenant-context'
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
  toast
} from '@ankole/uikit'
import { RiScales3Line, RiLoaderLine } from '@remixicon/react'

import { Fragment, useMemo, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'

import {
  decideBrainContradictionMutation,
  listBrainClaimsOptions,
  listBrainContradictionsInfiniteOptions
} from '../../api/v2/generated/@tanstack/react-query.gen'
import type { ListBrainContradictionsResponse } from '../../api/v2/generated/types.gen'
import { nextPageParams, fromDocument, type Flat } from '../../api/json-api'
import { requestErrorMessage } from '../../../common/request-errors'
import { linkTarget } from '../../../common/router'
import { DiscardConfirmDialog, LabeledField, useDialogDiscardGuard } from '../../console-form'
import { formatConsoleDate } from '../../console-primitives'
import { ResourceListPage } from '../../console-list-page'
import { BrainSubNav, brainObjectPath } from './brain-nav'

const CONTRADICTION_STATUSES = ['open', 'resolved', 'dismissed'] as const
const WIKI_LINK_PATTERN = /\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g

function renderClaimWithObjectLinks(text: string): ReactNode {
  const parts: ReactNode[] = []
  let lastIndex = 0
  for (const match of text.matchAll(WIKI_LINK_PATTERN)) {
    const matchIndex = match.index ?? 0
    if (matchIndex > lastIndex) parts.push(text.slice(lastIndex, matchIndex))
    const slug = (match[1] ?? '').trim()
    const label = (match[2] ?? slug).trim()
    if (slug) {
      parts.push(
        <Link key={`${matchIndex}:${slug}`} className="link font-mono" to={brainObjectPath(slug)}>
          {label}
        </Link>
      )
    } else {
      parts.push(match[0])
    }
    lastIndex = matchIndex + match[0].length
  }
  if (lastIndex === 0) return text
  if (lastIndex < text.length) parts.push(text.slice(lastIndex))
  return parts.map((part, index) => <Fragment key={index}>{part}</Fragment>)
}

type BrainContradiction = Flat<NonNullable<ListBrainContradictionsResponse['data']>[number]>

export function BrainContradictionsPage() {
  const { t } = useTranslation()
  const [status, setStatus] = useState<(typeof CONTRADICTION_STATUSES)[number]>('open')
  const [decideTarget, setDecideTarget] = useState<{
    contradiction: BrainContradiction
    decision: 'resolved' | 'dismissed'
  }>()
  const [note, setNote] = useState('')

  const contradictions = useInfiniteQuery({
    ...listBrainContradictionsInfiniteOptions({ query: { status } }),
    initialPageParam: {},
    getNextPageParam: nextPageParams,
    select: data => data.pages.flatMap(document => fromDocument(document))
  })
  const rows = contradictions.data ?? []
  const claims = useQuery({
    ...listBrainClaimsOptions(),
    select: document => fromDocument(document),
    enabled: rows.length > 0
  })
  const objectSlugByClaim = useMemo(() => {
    const map = new Map<string, string>()
    for (const claim of claims.data ?? []) {
      if (claim.claim && claim.object_slug && !map.has(claim.claim)) {
        map.set(claim.claim, claim.object_slug)
      }
    }
    return map
  }, [claims.data])

  // Reset per target so a note typed for one contradiction never carries to another.
  const openDecide = (contradiction: BrainContradiction, decision: 'resolved' | 'dismissed') => {
    setDecideTarget({ contradiction, decision })
    setNote('')
  }
  const decide = useMutation({
    ...decideBrainContradictionMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.contradiction_decided'))
      setDecideTarget(undefined)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const decideGuard = useDialogDiscardGuard({
    dirty: Boolean(decideTarget && note.trim()),
    onOpenChange: open => !open && setDecideTarget(undefined),
    pending: decide.isPending
  })

  const renderClaimRow = (badge: 'A' | 'B', text?: string | null) => {
    const objectSlug = text ? objectSlugByClaim.get(text) : undefined
    return (
      <div className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
        <Badge variant={badge === 'A' ? 'secondary' : 'outline'}>{badge}</Badge>
        <span>{text ? renderClaimWithObjectLinks(text) : '—'}</span>
        {objectSlug ? (
          <Link className="link font-mono text-[11px]" to={brainObjectPath(objectSlug)}>
            {objectSlug}
          </Link>
        ) : text ? (
          <Link
            className="link text-[11px] text-muted-foreground"
            {...linkTarget(`/brain/claims?search=${encodeURIComponent(text)}`)}>
            {t('console.brain.claims')}
          </Link>
        ) : null}
      </div>
    )
  }

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
        pagination={contradictions}
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
                <SelectValue />
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
                {renderClaimRow('A', contradiction.a_claim_text)}
                {renderClaimRow('B', contradiction.b_claim_text)}
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

      <Dialog open={Boolean(decideTarget)} onOpenChange={decideGuard.requestOpenChange}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!decide.isPending}>
          <DialogHeader>
            <DialogTitle>
              {decideTarget?.decision === 'resolved'
                ? t('console.brain.contradiction_resolve_title')
                : t('console.brain.contradiction_dismiss_title')}
            </DialogTitle>
            <DialogDescription>{t('console.brain.contradiction_decide_description')}</DialogDescription>
          </DialogHeader>
          <LabeledField label={t('console.brain.resolution_note')}>
            <Input value={note} onChange={event => setNote(event.target.value)} />
          </LabeledField>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={decide.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={decide.isPending}
              onClick={() =>
                decideTarget &&
                decide.mutate({
                  path: { contradiction_id: decideTarget.contradiction.id },
                  body: {
                    data: {
                      status: decideTarget.decision,
                      ...(note.trim() ? { resolution_note: note.trim() } : {})
                    }
                  }
                })
              }>
              {decide.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {decideTarget?.decision === 'resolved' ? t('console.brain.resolve') : t('console.brain.dismiss')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <DiscardConfirmDialog
        open={decideGuard.confirming}
        onDiscard={decideGuard.confirmDiscard}
        onKeep={decideGuard.keepEditing}
      />
    </>
  )
}
