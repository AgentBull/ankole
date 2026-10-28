import { TableRow, useMutation, useInfiniteQuery, Link, useSearchParams } from '../../tenant-context'
import {
  Badge,
  Button,
  buttonVariants,
  cn,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  Input,
  RadioGroup,
  RadioGroupItem,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  TableCell,
  Textarea,
  toast
} from '@ankole/uikit'
import { RiChatQuoteLine, RiLoaderLine, RiMore2Fill } from '@remixicon/react'
import { keepPreviousData } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'

import {
  forgetBrainClaimMutation,
  listBrainClaimsInfiniteOptions,
  resolveBrainTakeMutation,
  supersedeBrainClaimMutation
} from '../../api/v2/generated/@tanstack/react-query.gen'
import type { ListBrainClaimsResponse } from '../../api/v2/generated/types.gen'
import { nextPageParams, fromDocument, type Flat } from '../../api/json-api'
import { requestErrorMessage } from '../../../common/request-errors'

import { DiscardConfirmDialog, LabeledField, useDialogDiscardGuard } from '../../console-form'
import { formatConsoleDate } from '../../console-primitives'
import { FilterSwitch, ResourceListPage, ResourceSearch, useResourceSearchDraft } from '../../console-list-page'
import { BrainSubNav, brainObjectPath } from './brain-nav'
import { BrainHolderLabel } from './brain-scope'

const RESOLUTION_QUALITIES = ['correct', 'incorrect', 'partial', 'unresolvable'] as const

type ResolutionQuality = (typeof RESOLUTION_QUALITIES)[number]

type BrainClaim = Flat<NonNullable<ListBrainClaimsResponse['data']>[number]>

/** The Claim fields that give the state badge, in the v2 list and the v1 audit read model. */
type ClaimState = {
  claim_type: string
  superseded_by?: string | null
  expired_at?: string | null
  resolved_at?: string | null
  resolved_quality?: string | null
  active?: boolean | null
}

export function BrainClaimsPage() {
  const { t } = useTranslation()
  const [searchParams] = useSearchParams()
  // Search and the slug filter query the server, so both commit on the shared
  // debounce instead of issuing one request per keystroke.
  const [query, setQuery] = useState(() => searchParams.get('search') ?? '')
  const [queryDraft, setQueryDraft] = useResourceSearchDraft(query, setQuery)
  const [claimType, setClaimType] = useState<'all' | 'fact' | 'take'>('all')
  const [currentOnly, setCurrentOnly] = useState(true)
  const [objectSlug, setObjectSlug] = useState(() => searchParams.get('object_slug') ?? '')
  const [slugDraft, setSlugDraft] = useResourceSearchDraft(objectSlug, setObjectSlug)

  const claims = useInfiniteQuery({
    ...listBrainClaimsInfiniteOptions({
      query: {
        ...(claimType === 'all' ? {} : { claim_type: claimType }),
        ...(currentOnly ? { status: 'current' } : {}),
        ...(objectSlug.trim() ? { object_slug: objectSlug.trim() } : {}),
        ...(query.trim() ? { search: query.trim() } : {})
      }
    }),
    initialPageParam: {},
    getNextPageParam: nextPageParams,
    select: data => data.pages.flatMap(document => fromDocument(document)),
    placeholderData: keepPreviousData
  })
  const rows = claims.data ?? []

  const [supersedeClaim, setSupersedeClaim] = useState<BrainClaim>()
  const [forgetClaim, setForgetClaim] = useState<BrainClaim>()
  const [resolveClaim, setResolveClaim] = useState<BrainClaim>()

  return (
    <>
      <ResourceListPage
        title={t('console.brain.claims_title')}
        description={t('console.brain.claims_description')}
        subNav={<BrainSubNav />}
        columns={[
          t('console.brain.claim'),
          t('console.brain.type'),
          t('console.brain.holder'),
          t('console.brain.object'),
          t('console.brain.state'),
          t('console.brain.created')
        ]}
        isLoading={claims.isLoading}
        isEmpty={rows.length === 0}
        count={rows.length}
        emptyTitle={t('console.brain.claims_empty_title')}
        emptyDescription={t('console.brain.claims_empty_description')}
        emptyIcon={<RiChatQuoteLine aria-hidden />}
        pagination={claims}
        isFiltered={Boolean(query.trim() || objectSlug.trim() || claimType !== 'all' || !currentOnly)}
        onClearFilters={() => {
          setQuery('')
          setQueryDraft('')
          setObjectSlug('')
          setSlugDraft('')
          setClaimType('all')
          setCurrentOnly(true)
        }}
        emptyAction={
          <Link className={cn(buttonVariants({ size: 'sm', variant: 'outline' }))} to="/brain/health">
            {t('console.brain.empty_check_health')}
          </Link>
        }
        toolbarCanRevealRows
        toolbar={
          <ResourceSearch
            label={t('console.brain.claims_search')}
            placeholder={t('console.brain.claims_search_placeholder')}
            value={queryDraft}
            onChange={setQueryDraft}
            filters={
              <>
                <Input
                  aria-label={t('console.brain.object_slug_filter')}
                  className="w-56 font-mono text-xs"
                  placeholder={t('console.brain.object_slug_filter')}
                  spellCheck={false}
                  value={slugDraft}
                  onChange={event => setSlugDraft(event.target.value)}
                />
                <Select
                  value={claimType}
                  onValueChange={value => {
                    if (value === 'all' || value === 'fact' || value === 'take') setClaimType(value)
                  }}>
                  <SelectTrigger aria-label={t('console.brain.type')} size="sm">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="all">{t('console.brain.claim_type_all')}</SelectItem>
                    <SelectItem value="fact">{t('console.brain.claim_type_fact')}</SelectItem>
                    <SelectItem value="take">{t('console.brain.claim_type_take')}</SelectItem>
                  </SelectContent>
                </Select>
                <FilterSwitch checked={currentOnly} label={t('console.brain.current_only')} onChange={setCurrentOnly} />
              </>
            }
          />
        }>
        {rows.map(claim => {
          const resolved = claim.claim_type === 'take' && Boolean(claim.resolved_at)

          return (
            <TableRow key={claim.id} className={resolved ? 'opacity-70' : undefined}>
              <TableCell className="min-w-72 max-w-[380px] whitespace-normal break-words text-sm leading-6">
                {claim.claim}
              </TableCell>
              <TableCell>
                <Badge variant={claim.claim_type === 'fact' ? 'secondary' : 'info'}>
                  {t(`console.brain.claim_type_${claim.claim_type}`)}
                  {claim.kind ? ` · ${claim.kind}` : ''}
                </Badge>
              </TableCell>
              <TableCell>
                <BrainHolderLabel holder={claim.holder} />
              </TableCell>
              <TableCell className="font-mono text-xs">
                {claim.object_slug ? (
                  <Link className="link" to={brainObjectPath(claim.object_slug)}>
                    {claim.object_slug}
                  </Link>
                ) : (
                  '—'
                )}
              </TableCell>
              <TableCell>
                <ClaimStateBadge claim={claim} />
              </TableCell>
              <TableCell className="text-xs text-muted-foreground">{formatConsoleDate(claim.created_at)}</TableCell>
              {resolved ? (
                <TableCell className="text-right">
                  <span className="pr-2 text-xs text-muted-foreground">{t('console.brain.read_only')}</span>
                </TableCell>
              ) : (
                <TableCell className="text-right">
                  <DropdownMenu>
                    <DropdownMenuTrigger
                      render={
                        <Button size="icon-sm" type="button" variant="ghost" aria-label={t('common.more_actions')} />
                      }>
                      <RiMore2Fill />
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="end">
                      <DropdownMenuItem onClick={() => setSupersedeClaim(claim)}>
                        {t('console.brain.supersede')}
                      </DropdownMenuItem>
                      <DropdownMenuItem onClick={() => setForgetClaim(claim)}>
                        {t('console.brain.forget')}
                      </DropdownMenuItem>
                      {claim.claim_type === 'take' ? (
                        <DropdownMenuItem onClick={() => setResolveClaim(claim)}>
                          {t('console.brain.resolve')}
                        </DropdownMenuItem>
                      ) : null}
                    </DropdownMenuContent>
                  </DropdownMenu>
                </TableCell>
              )}
            </TableRow>
          )
        })}
      </ResourceListPage>

      <SupersedeClaimDialog claim={supersedeClaim} onClose={() => setSupersedeClaim(undefined)} />
      <ForgetClaimDialog claim={forgetClaim} onClose={() => setForgetClaim(undefined)} />
      <ResolveTakeDialog claim={resolveClaim} onClose={() => setResolveClaim(undefined)} />
    </>
  )
}

export function ClaimStateBadge({ claim }: { claim: ClaimState }) {
  const { t } = useTranslation()

  if (claim.superseded_by) return <Badge variant="outline">{t('console.brain.superseded')}</Badge>
  if (claim.claim_type === 'fact') {
    return claim.expired_at ? (
      <Badge variant="outline">{t('console.brain.expired')}</Badge>
    ) : (
      <Badge variant="success">{t('console.brain.current')}</Badge>
    )
  }
  if (claim.resolved_at) {
    return <Badge variant="info">{t('console.brain.resolved', { quality: claim.resolved_quality ?? '' })}</Badge>
  }
  return claim.active ? (
    <Badge variant="success">{t('console.brain.active')}</Badge>
  ) : (
    <Badge variant="outline">{t('console.brain.inactive')}</Badge>
  )
}

function SupersedeClaimDialog({ claim, onClose }: { claim?: BrainClaim; onClose: () => void }) {
  const { t } = useTranslation()
  const [text, setText] = useState('')
  const [seededFor, setSeededFor] = useState<string>()
  if (claim && seededFor !== claim.id) {
    setSeededFor(claim.id)
    setText(claim.claim)
  }

  const supersede = useMutation({
    ...supersedeBrainClaimMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.supersede_done'))
      onClose()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const guard = useDialogDiscardGuard({
    dirty: claim !== undefined && text !== claim.claim,
    onOpenChange: open => !open && onClose(),
    pending: supersede.isPending
  })

  return (
    <>
      <Dialog open={Boolean(claim)} onOpenChange={guard.requestOpenChange}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!supersede.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.brain.supersede_title')}</DialogTitle>
            <DialogDescription>{t('console.brain.supersede_description')}</DialogDescription>
          </DialogHeader>
          <LabeledField label={t('console.brain.supersede_text')} required>
            <Textarea
              className="min-h-28 text-sm"
              required
              value={text}
              onChange={event => setText(event.target.value)}
            />
          </LabeledField>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={supersede.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={supersede.isPending || !text.trim() || text.trim() === claim?.claim}
              onClick={() =>
                supersede.mutate({ path: { claim_id: claim?.id ?? '' }, body: { data: { claim: text.trim() } } })
              }>
              {supersede.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.brain.supersede')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <DiscardConfirmDialog open={guard.confirming} onDiscard={guard.confirmDiscard} onKeep={guard.keepEditing} />
    </>
  )
}

function ForgetClaimDialog({ claim, onClose }: { claim?: BrainClaim; onClose: () => void }) {
  const { t } = useTranslation()
  const [reason, setReason] = useState('')
  const [seededFor, setSeededFor] = useState<string>()
  // Reset per target so a reason typed for one claim never carries to another.
  if (claim && seededFor !== claim.id) {
    setSeededFor(claim.id)
    setReason('')
  }

  const forget = useMutation({
    ...forgetBrainClaimMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.forget_claim_done'))
      onClose()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const guard = useDialogDiscardGuard({
    dirty: Boolean(claim && reason.trim()),
    onOpenChange: open => !open && onClose(),
    pending: forget.isPending
  })

  return (
    <>
      <Dialog open={Boolean(claim)} onOpenChange={guard.requestOpenChange}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!forget.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.brain.forget_claim_title')}</DialogTitle>
            <DialogDescription>{t('console.brain.forget_claim_description')}</DialogDescription>
          </DialogHeader>
          <LabeledField label={t('console.brain.forget_reason')} required>
            <Input required value={reason} onChange={event => setReason(event.target.value)} />
          </LabeledField>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={forget.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={forget.isPending || !reason.trim()}
              variant="destructive"
              onClick={() =>
                forget.mutate({ path: { claim_id: claim?.id ?? '' }, body: { data: { reason: reason.trim() } } })
              }>
              {forget.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.brain.forget')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <DiscardConfirmDialog open={guard.confirming} onDiscard={guard.confirmDiscard} onKeep={guard.keepEditing} />
    </>
  )
}

function ResolveTakeDialog({ claim, onClose }: { claim?: BrainClaim; onClose: () => void }) {
  const { t } = useTranslation()
  const [quality, setQuality] = useState<ResolutionQuality>('correct')
  const [outcome, setOutcome] = useState(true)
  const [provenance, setProvenance] = useState('')
  const [seededFor, setSeededFor] = useState<string>()
  // Reset per target so one take's resolution never pre-fills another's.
  if (claim && seededFor !== claim.id) {
    setSeededFor(claim.id)
    setQuality('correct')
    setOutcome(true)
    setProvenance('')
  }
  const outcomeRequired = quality === 'correct' || quality === 'incorrect'

  const resolve = useMutation({
    ...resolveBrainTakeMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.resolve_done'))
      onClose()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const guard = useDialogDiscardGuard({
    dirty: Boolean(claim) && (quality !== 'correct' || !outcome || Boolean(provenance.trim())),
    onOpenChange: open => !open && onClose(),
    pending: resolve.isPending
  })

  return (
    <>
      <Dialog open={Boolean(claim)} onOpenChange={guard.requestOpenChange}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!resolve.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.brain.resolve_title')}</DialogTitle>
            <DialogDescription>{t('console.brain.resolve_description')}</DialogDescription>
          </DialogHeader>
          <div className="grid gap-4">
            {claim?.graded_quality ? (
              <p className="border border-border bg-muted/30 px-3 py-2 text-xs text-muted-foreground">
                {t('console.brain.graded_reference', {
                  quality: claim.graded_quality,
                  confidence: claim.graded_confidence ?? '—'
                })}
              </p>
            ) : null}
            <LabeledField label={t('console.brain.resolve_quality')}>
              <Select
                value={quality}
                onValueChange={value => {
                  if (typeof value === 'string' && (RESOLUTION_QUALITIES as readonly string[]).includes(value)) {
                    setQuality(value as ResolutionQuality)
                  }
                }}>
                <SelectTrigger aria-label={t('console.brain.resolve_quality')} className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {RESOLUTION_QUALITIES.map(option => (
                    <SelectItem key={option} value={option}>
                      {t(`console.brain.resolve_quality_${option}`)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </LabeledField>
            {outcomeRequired ? (
              <LabeledField label={t('console.brain.resolve_outcome')}>
                <RadioGroup
                  aria-label={t('console.brain.resolve_outcome')}
                  className="flex items-center gap-6 pt-1"
                  value={outcome ? 'true' : 'false'}
                  onValueChange={value => setOutcome(value === 'true')}>
                  <label className="flex cursor-pointer items-center gap-2 text-sm text-foreground">
                    <RadioGroupItem value="true" />
                    {t('common.boolean_true')}
                  </label>
                  <label className="flex cursor-pointer items-center gap-2 text-sm text-foreground">
                    <RadioGroupItem value="false" />
                    {t('common.boolean_false')}
                  </label>
                </RadioGroup>
              </LabeledField>
            ) : null}
            <LabeledField label={t('console.brain.resolve_provenance')}>
              <Input value={provenance} onChange={event => setProvenance(event.target.value)} />
            </LabeledField>
          </div>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={resolve.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={resolve.isPending}
              onClick={() =>
                resolve.mutate({
                  path: { claim_id: claim?.id ?? '' },
                  body: {
                    data: {
                      resolved_quality: quality,
                      resolved_outcome: outcomeRequired ? outcome : null,
                      resolution_provenance: provenance.trim() || null
                    }
                  }
                })
              }>
              {resolve.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.brain.resolve')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <DiscardConfirmDialog open={guard.confirming} onDiscard={guard.confirmDiscard} onKeep={guard.keepEditing} />
    </>
  )
}
