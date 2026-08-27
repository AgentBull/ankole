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
  Textarea,
  toast
} from '@ankole/uikit'
import { RiChatQuoteLine, RiLoaderLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router'
import {
  ankoleWebBrainControllerForgetClaimMutation,
  ankoleWebBrainControllerListClaimsOptions,
  ankoleWebBrainControllerListClaimsQueryKey,
  ankoleWebBrainControllerResolveTakeMutation,
  ankoleWebBrainControllerSupersedeClaimMutation
} from '../../api/generated/@tanstack/react-query.gen'
import type { BrainClaim } from '../../api/generated/types.gen'
import { requestErrorMessage } from '../../../common/request-errors'
import { formatConsoleDate } from '../../console-primitives'
import { FilterSwitch, ResourceListPage, ResourceSearch } from '../../console-list-page'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../../state/resource-search'
import { BrainSubNav, brainObjectPath } from './brain-nav'

const RESOLUTION_QUALITIES = ['correct', 'incorrect', 'partial', 'unresolvable'] as const

type ResolutionQuality = (typeof RESOLUTION_QUALITIES)[number]

export function BrainClaimsPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [query, setQuery] = useState('')
  const [claimType, setClaimType] = useState<'all' | 'fact' | 'take'>('all')
  const [currentOnly, setCurrentOnly] = useState(true)
  const [objectSlug, setObjectSlug] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const deferredSlug = useDeferredValue(objectSlug)

  const claims = useQuery(
    ankoleWebBrainControllerListClaimsOptions({
      query: {
        ...(claimType === 'all' ? {} : { claim_type: claimType }),
        ...(currentOnly ? { status: 'current' } : {}),
        ...(deferredSlug.trim() ? { object_slug: deferredSlug.trim() } : {})
      }
    })
  )
  const rows = (claims.data?.claims ?? []).filter(claim =>
    matchesResourceSearch(searchQuery, claim.claim, claim.kind, claim.holder, claim.object_slug, claim.author_uid)
  )

  const invalidate = () =>
    void queryClient.invalidateQueries({ queryKey: ankoleWebBrainControllerListClaimsQueryKey() })
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
        error={claims.error}
        isFiltered={Boolean(query.trim() || objectSlug.trim() || claimType !== 'all' || !currentOnly)}
        onClearFilters={() => {
          setQuery('')
          setObjectSlug('')
          setClaimType('all')
          setCurrentOnly(true)
        }}
        toolbarCanRevealRows
        toolbar={
          <ResourceSearch
            label={t('console.brain.claims_search')}
            placeholder={t('console.brain.claims_search_placeholder')}
            value={query}
            onChange={setQuery}
            filters={
              <>
                <Input
                  aria-label={t('console.brain.object_slug_filter')}
                  className="w-56 font-mono text-xs"
                  placeholder={t('console.brain.object_slug_filter')}
                  spellCheck={false}
                  value={objectSlug}
                  onChange={event => setObjectSlug(event.target.value)}
                />
                <Select
                  value={claimType}
                  onValueChange={value => {
                    if (value === 'all' || value === 'fact' || value === 'take') setClaimType(value)
                  }}>
                  <SelectTrigger aria-label={t('console.brain.type')} size="sm">
                    <SelectValue>{value => t(`console.brain.claim_type_${String(value)}`)}</SelectValue>
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
          const resolved = claim.claim_type === 'take' && claim.resolved_at !== null

          return (
            <TableRow key={claim.id} className={resolved ? 'opacity-70' : undefined}>
              <TableCell className="max-w-[380px] whitespace-normal text-xs">{claim.claim}</TableCell>
              <TableCell>
                <Badge variant={claim.claim_type === 'fact' ? 'secondary' : 'info'}>
                  {t(`console.brain.claim_type_${claim.claim_type}`)}
                  {claim.kind ? ` · ${claim.kind}` : ''}
                </Badge>
              </TableCell>
              <TableCell className="font-mono text-xs">{claim.holder ?? '—'}</TableCell>
              <TableCell className="font-mono text-xs">
                {claim.object_slug ? (
                  <Link className="text-link hover:underline" to={brainObjectPath(claim.object_slug)}>
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
                  <div className="flex justify-end gap-1">
                    <Button size="xs" type="button" variant="ghost" onClick={() => setSupersedeClaim(claim)}>
                      {t('console.brain.supersede')}
                    </Button>
                    <Button size="xs" type="button" variant="ghost" onClick={() => setForgetClaim(claim)}>
                      {t('console.brain.forget')}
                    </Button>
                    {claim.claim_type === 'take' ? (
                      <Button size="xs" type="button" variant="ghost" onClick={() => setResolveClaim(claim)}>
                        {t('console.brain.resolve')}
                      </Button>
                    ) : null}
                  </div>
                </TableCell>
              )}
            </TableRow>
          )
        })}
      </ResourceListPage>

      <SupersedeClaimDialog claim={supersedeClaim} onClose={() => setSupersedeClaim(undefined)} onDone={invalidate} />
      <ForgetClaimDialog claim={forgetClaim} onClose={() => setForgetClaim(undefined)} onDone={invalidate} />
      <ResolveTakeDialog claim={resolveClaim} onClose={() => setResolveClaim(undefined)} onDone={invalidate} />
    </>
  )
}

export function ClaimStateBadge({ claim }: { claim: BrainClaim }) {
  const { t } = useTranslation()

  if (claim.superseded_by) return <Badge variant="outline">{t('console.brain.superseded')}</Badge>
  if (claim.claim_type === 'fact') {
    return claim.expired_at ? (
      <Badge variant="outline">{t('console.brain.expired')}</Badge>
    ) : (
      <Badge variant="success">{t('console.brain.current')}</Badge>
    )
  }
  if (claim.resolved_at)
    {return <Badge variant="info">{t('console.brain.resolved', { quality: claim.resolved_quality ?? '' })}</Badge>}
  return claim.active ? (
    <Badge variant="success">{t('console.status.active')}</Badge>
  ) : (
    <Badge variant="outline">{t('console.brain.inactive')}</Badge>
  )
}

function SupersedeClaimDialog({
  claim,
  onClose,
  onDone
}: {
  claim?: BrainClaim
  onClose: () => void
  onDone: () => void
}) {
  const { t } = useTranslation()
  const [text, setText] = useState('')
  const [seededFor, setSeededFor] = useState<string>()
  if (claim && seededFor !== claim.id) {
    setSeededFor(claim.id)
    setText(claim.claim)
  }

  const supersede = useMutation({
    ...ankoleWebBrainControllerSupersedeClaimMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.supersede_done'))
      onDone()
      onClose()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <Dialog open={Boolean(claim)} onOpenChange={open => !supersede.isPending && !open && onClose()}>
      <DialogContent closeLabel={t('common.close')} showCloseButton={!supersede.isPending}>
        <DialogHeader>
          <DialogTitle>{t('console.brain.supersede_title')}</DialogTitle>
          <DialogDescription>{t('console.brain.supersede_description')}</DialogDescription>
        </DialogHeader>
        <Textarea
          aria-label={t('console.brain.supersede_text')}
          className="min-h-28 text-sm"
          value={text}
          onChange={event => setText(event.target.value)}
        />
        <DialogFooter>
          <DialogClose render={<Button variant="outline" />} disabled={supersede.isPending}>
            {t('common.cancel')}
          </DialogClose>
          <Button
            disabled={supersede.isPending || !text.trim() || text.trim() === claim?.claim}
            onClick={() => supersede.mutate({ path: { claim_id: claim?.id ?? '' }, body: { claim: text.trim() } })}>
            {supersede.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
            {t('console.brain.supersede')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function ForgetClaimDialog({
  claim,
  onClose,
  onDone
}: {
  claim?: BrainClaim
  onClose: () => void
  onDone: () => void
}) {
  const { t } = useTranslation()
  const [reason, setReason] = useState('')
  const [seededFor, setSeededFor] = useState<string>()
  // Reset per target so a reason typed for one claim never carries to another.
  if (claim && seededFor !== claim.id) {
    setSeededFor(claim.id)
    setReason('')
  }

  const forget = useMutation({
    ...ankoleWebBrainControllerForgetClaimMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.forget_claim_done'))
      onDone()
      onClose()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <Dialog open={Boolean(claim)} onOpenChange={open => !forget.isPending && !open && onClose()}>
      <DialogContent closeLabel={t('common.close')} showCloseButton={!forget.isPending}>
        <DialogHeader>
          <DialogTitle>{t('console.brain.forget_claim_title')}</DialogTitle>
          <DialogDescription>{t('console.brain.forget_claim_description')}</DialogDescription>
        </DialogHeader>
        <Input
          aria-label={t('console.brain.forget_reason')}
          placeholder={t('console.brain.forget_reason')}
          value={reason}
          onChange={event => setReason(event.target.value)}
        />
        <DialogFooter>
          <DialogClose render={<Button variant="outline" />} disabled={forget.isPending}>
            {t('common.cancel')}
          </DialogClose>
          <Button
            disabled={forget.isPending || !reason.trim()}
            variant="destructive"
            onClick={() => forget.mutate({ path: { claim_id: claim?.id ?? '' }, body: { reason: reason.trim() } })}>
            {forget.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
            {t('console.brain.forget')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function ResolveTakeDialog({
  claim,
  onClose,
  onDone
}: {
  claim?: BrainClaim
  onClose: () => void
  onDone: () => void
}) {
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
    ...ankoleWebBrainControllerResolveTakeMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.resolve_done'))
      onDone()
      onClose()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <Dialog open={Boolean(claim)} onOpenChange={open => !resolve.isPending && !open && onClose()}>
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
          <label className="grid gap-1.5 text-xs text-muted-foreground">
            {t('console.brain.resolve_quality')}
            <Select
              value={quality}
              onValueChange={value => {
                if (typeof value === 'string' && (RESOLUTION_QUALITIES as readonly string[]).includes(value)) {
                  setQuality(value as ResolutionQuality)
                }
              }}>
              <SelectTrigger aria-label={t('console.brain.resolve_quality')} className="w-full">
                <SelectValue>{value => t(`console.brain.resolve_quality_${String(value)}`)}</SelectValue>
              </SelectTrigger>
              <SelectContent>
                {RESOLUTION_QUALITIES.map(option => (
                  <SelectItem key={option} value={option}>
                    {t(`console.brain.resolve_quality_${option}`)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </label>
          {outcomeRequired ? (
            <label className="grid gap-1.5 text-xs text-muted-foreground">
              {t('console.brain.resolve_outcome')}
              <Select value={outcome ? 'true' : 'false'} onValueChange={value => value && setOutcome(value === 'true')}>
                <SelectTrigger aria-label={t('console.brain.resolve_outcome')} className="w-full">
                  <SelectValue>
                    {value => (value === 'true' ? t('common.boolean_true') : t('common.boolean_false'))}
                  </SelectValue>
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="true">{t('common.boolean_true')}</SelectItem>
                  <SelectItem value="false">{t('common.boolean_false')}</SelectItem>
                </SelectContent>
              </Select>
            </label>
          ) : null}
          <label className="grid gap-1.5 text-xs text-muted-foreground">
            {t('console.brain.resolve_provenance')}
            <Input value={provenance} onChange={event => setProvenance(event.target.value)} />
          </label>
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
                  ['resolved_quality']: quality,
                  ['resolved_outcome']: outcomeRequired ? outcome : null,
                  ['resolution_provenance']: provenance.trim() || null
                }
              })
            }>
            {resolve.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
            {t('console.brain.resolve')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
