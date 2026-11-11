import {
  Badge,
  Button,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  toast
} from '@ankole/uikit'
import {
  AddRegular,
  BuildingRegular,
  DeleteRegular,
  DocumentTextRegular,
  EditRegular,
  LockClosedRegular
} from '@ankole/uikit/icons'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorMessage } from '../common/request-errors'
import { ContentError, InlineLoading } from './content-primitives'
import {
  brainClaimsAPI,
  metaBrainMyContextQuery,
  metaBrainNodeClaimsQuery,
  metaKeys,
  type MetaBrainClaim
} from './meta-api'
import { usePageHref } from './use-page-metadata'

const FACT_KINDS = ['preference', 'fact', 'commitment', 'belief', 'event'] as const

function invalidateBrainClaims(client: ReturnType<typeof useQueryClient>, pageId?: string) {
  void client.invalidateQueries({ queryKey: metaKeys.brainMyContext() })
  if (pageId) {
    void client.invalidateQueries({ queryKey: metaKeys.brainNodeClaims(pageId) })
  } else {
    void client.invalidateQueries({ queryKey: [...metaKeys.brain(), 'node-claims'] })
  }
}

function BrainClaimRow({
  claim,
  compact = false,
  contextPageId
}: {
  claim: MetaBrainClaim
  compact?: boolean
  contextPageId?: string
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const pageHref = usePageHref()
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(claim.claim)

  const supersede = useMutation({
    mutationFn: (nextClaim: string) => brainClaimsAPI.supersedeClaim(claim.id, nextClaim),
    onSuccess: () => {
      setEditing(false)
      invalidateBrainClaims(client, contextPageId)
      toast.success(t('pod.meta.claim_updated'))
    },
    onError: error => {
      toast.error(requestErrorMessage(error))
    }
  })

  const forget = useMutation({
    mutationFn: () => brainClaimsAPI.forgetClaim(claim.id, 'Forgotten by viewer in Meta Brain'),
    onSuccess: () => {
      invalidateBrainClaims(client, contextPageId)
      toast.success(t('pod.meta.claim_forgotten'))
    },
    onError: error => {
      toast.error(requestErrorMessage(error))
    }
  })

  const busy = supersede.isPending || forget.isPending
  const shortPreview = claim.claim.length > 48 ? `${claim.claim.slice(0, 48)}…` : claim.claim
  const inputId = `claim-edit-${claim.id}`

  return (
    <li className="rounded-control border border-border/80 bg-bg-primary/65 p-2.5 text-xs">
      {editing ? (
        <form
          className="space-y-2"
          onSubmit={event => {
            event.preventDefault()
            const trimmed = draft.trim()
            if (!trimmed || busy) return
            if (trimmed === claim.claim) {
              setEditing(false)
              return
            }
            supersede.mutate(trimmed)
          }}>
          <label htmlFor={inputId} className="block text-[11px] font-medium text-fg-secondary">
            {t('pod.meta.claim_edit_label')}
          </label>
          <textarea
            id={inputId}
            name="claim"
            rows={compact ? 2 : 3}
            value={draft}
            disabled={busy}
            required
            onChange={event => setDraft(event.currentTarget.value)}
            onKeyDown={event => {
              if (event.key === 'Enter' && !event.shiftKey) {
                event.preventDefault()
                if (event.nativeEvent.isComposing || event.keyCode === 229) return
                event.currentTarget.form?.requestSubmit()
              } else if (event.key === 'Escape') {
                event.preventDefault()
                setEditing(false)
                setDraft(claim.claim)
              }
            }}
            className="w-full rounded-control border border-border bg-bg-primary px-2.5 py-1.5 text-xs text-fg-primary focus-visible:outline-2 focus-visible:outline-offset-1"
          />
          <div className="flex items-center justify-end gap-1.5">
            <Button
              type="button"
              size="xs"
              variant="ghost"
              disabled={busy}
              onClick={() => {
                setEditing(false)
                setDraft(claim.claim)
              }}>
              {t('common.cancel')}
            </Button>
            <Button type="submit" size="xs" disabled={busy}>
              {t('pod.meta.claim_save')}
            </Button>
          </div>
        </form>
      ) : (
        <div className="space-y-1.5">
          <p className="leading-relaxed text-fg-primary">{claim.claim}</p>
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex min-w-0 flex-wrap items-center gap-1.5 text-[11px] text-fg-tertiary">
              <Badge variant="outline" className="px-1.5 py-0 font-mono text-[10px]">
                {t(`pod.meta.claim_kind_${claim.kind}`, { defaultValue: claim.kind })}
              </Badge>
              {claim.source_title && !contextPageId && (
                <Link
                  to={pageHref(claim.source_node_id, claim.source_title)}
                  className="inline-flex max-w-48 items-center gap-1 truncate rounded bg-bg-secondary px-1.5 py-0.5 text-fg-secondary hover:text-fg-primary hover:underline">
                  <DocumentTextRegular aria-hidden className="size-3 shrink-0" />
                  <span className="truncate">{claim.source_title}</span>
                </Link>
              )}
              {claim.subject_title && contextPageId && claim.subject_page_id !== contextPageId && (
                <Link
                  to={`/meta/brain/${claim.subject_page_id}`}
                  className="max-w-36 truncate text-fg-secondary hover:text-fg-primary hover:underline">
                  {claim.subject_title}
                </Link>
              )}
            </div>
            {(claim.can_edit || claim.can_forget) && (
              <div className="flex shrink-0 items-center gap-1">
                {claim.can_edit && (
                  <Button
                    type="button"
                    size="xs"
                    variant="ghost"
                    disabled={busy}
                    aria-label={`${t('pod.meta.claim_correct')}: ${shortPreview}`}
                    onClick={() => {
                      setDraft(claim.claim)
                      setEditing(true)
                    }}>
                    <EditRegular aria-hidden className="size-3" />
                    <span>{t('pod.meta.claim_correct')}</span>
                  </Button>
                )}
                {claim.can_forget && (
                  <Button
                    type="button"
                    size="xs"
                    variant="ghost"
                    disabled={busy}
                    aria-label={`${t('pod.meta.claim_forget')}: ${shortPreview}`}
                    onClick={() => forget.mutate()}>
                    <DeleteRegular aria-hidden className="size-3" />
                    <span>{t('pod.meta.claim_forget')}</span>
                  </Button>
                )}
              </div>
            )}
          </div>
        </div>
      )}
    </li>
  )
}

export function BrainNodeClaimsSection({ pageId }: { pageId: string }) {
  const { t } = useTranslation()
  const claimsQuery = useQuery(metaBrainNodeClaimsQuery(pageId))
  const claims = claimsQuery.data?.claims ?? []

  return (
    <div className="space-y-1.5 border-t border-border/70 pt-2.5">
      <div className="flex items-center justify-between gap-2 text-[11px] font-medium text-fg-tertiary">
        <span>{t('pod.meta.active_claims')}</span>
        {!claimsQuery.isPending && <span className="font-mono">{claims.length}</span>}
      </div>
      {claimsQuery.isPending ? (
        <InlineLoading label={t('pod.meta.loading_claims')} />
      ) : claimsQuery.error ? (
        <ContentError error={claimsQuery.error} retry={() => void claimsQuery.refetch()} />
      ) : claims.length === 0 ? (
        <p className="text-[11px] text-fg-tertiary">{t('pod.meta.no_active_claims')}</p>
      ) : (
        <ul className="max-h-52 space-y-1.5 overflow-y-auto pr-0.5">
          {claims.map(claim => (
            <BrainClaimRow key={claim.id} claim={claim} compact contextPageId={pageId} />
          ))}
        </ul>
      )}
    </div>
  )
}

export function BrainMyContextView() {
  const { t } = useTranslation()
  const client = useQueryClient()
  const contextQuery = useQuery(metaBrainMyContextQuery())
  const [filter, setFilter] = useState('')
  const [newClaim, setNewClaim] = useState('')
  const [newKind, setNewKind] = useState<(typeof FACT_KINDS)[number]>('preference')

  const addFact = useMutation({
    mutationFn: (body: { claim: string; kind: string }) => brainClaimsAPI.addMyFact(body),
    onSuccess: () => {
      setNewClaim('')
      invalidateBrainClaims(client)
      toast.success(t('pod.meta.memory_added'))
    },
    onError: error => {
      toast.error(requestErrorMessage(error))
    }
  })

  const normalizedFilter = filter.trim().toLocaleLowerCase()
  const { personalClaims, workspaceClaims } = useMemo(() => {
    const all = contextQuery.data?.claims ?? []
    const matched = normalizedFilter
      ? all.filter(item => {
          const haystack = `${item.claim} ${item.kind} ${item.source_title ?? ''}`.toLocaleLowerCase()
          return haystack.includes(normalizedFilter)
        })
      : all
    return {
      personalClaims: matched.filter(item => item.bucket === 'personal'),
      workspaceClaims: matched.filter(item => item.bucket !== 'personal')
    }
  }, [contextQuery.data?.claims, normalizedFilter])

  const assistantUid = contextQuery.data?.assistant_uid

  return (
    <div className="space-y-6">
      <div className="ceramic rounded-control border border-border p-4 shadow-xs">
        <h2 id="brain-add-memory-heading" className="text-sm font-semibold text-fg-primary">
          {t('pod.meta.add_personal_memory')}
        </h2>
        <p id="brain-add-memory-hint" className="mt-0.5 text-xs text-fg-secondary">
          {assistantUid
            ? t('pod.meta.personal_memory_scope_with_assistant', { assistant: assistantUid })
            : t('pod.meta.personal_memory_scope_desc')}
        </p>
        <form
          aria-labelledby="brain-add-memory-heading"
          className="mt-3 flex flex-wrap items-end gap-2.5"
          onSubmit={event => {
            event.preventDefault()
            const trimmed = newClaim.trim()
            if (!trimmed || addFact.isPending) return
            addFact.mutate({ claim: trimmed, kind: newKind })
          }}>
          <div className="min-w-60 flex-1">
            <label htmlFor="brain-new-memory-claim" className="mb-1 block text-xs font-medium text-fg-secondary">
              {t('pod.meta.memory_statement')}
            </label>
            <Input
              id="brain-new-memory-claim"
              name="claim"
              value={newClaim}
              aria-describedby="brain-add-memory-hint"
              placeholder={t('pod.meta.memory_placeholder')}
              disabled={addFact.isPending}
              required
              onChange={event => setNewClaim(event.currentTarget.value)}
            />
          </div>
          <div className="w-40">
            <label id="brain-new-memory-kind-label" className="mb-1 block text-xs font-medium text-fg-secondary">
              {t('pod.meta.memory_kind')}
            </label>
            <Select
              value={newKind}
              disabled={addFact.isPending}
              onValueChange={val => setNewKind(val as (typeof FACT_KINDS)[number])}>
              <SelectTrigger aria-labelledby="brain-new-memory-kind-label" className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {FACT_KINDS.map(kind => (
                  <SelectItem key={kind} value={kind}>
                    {t(`pod.meta.claim_kind_${kind}`, { defaultValue: kind })}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <Button type="submit" disabled={addFact.isPending}>
            <AddRegular aria-hidden className="size-4" />
            <span>{t('pod.meta.save_memory')}</span>
          </Button>
        </form>
      </div>

      <search>
        <div className="max-w-md">
          <label htmlFor="brain-my-context-filter" className="mb-1 block text-sm font-medium text-fg-primary">
            {t('pod.meta.filter_memories')}
          </label>
          <Input
            id="brain-my-context-filter"
            name="q"
            type="search"
            value={filter}
            autoCorrect="off"
            autoCapitalize="none"
            spellCheck={false}
            onChange={event => setFilter(event.currentTarget.value)}
          />
        </div>
      </search>

      {contextQuery.error && <ContentError error={contextQuery.error} retry={() => void contextQuery.refetch()} />}
      {contextQuery.isPending && <InlineLoading label={t('pod.meta.loading_claims')} />}

      {!contextQuery.isPending && !contextQuery.error && (
        <div className="grid gap-6 lg:grid-cols-2">
          <section className="space-y-3 rounded-control border border-border p-4">
            <div className="flex items-start justify-between gap-2">
              <div className="space-y-0.5">
                <h2 className="flex items-center gap-1.5 text-sm font-semibold text-fg-primary">
                  <LockClosedRegular aria-hidden className="size-4 text-fg-secondary" />
                  <span>{t('pod.meta.personal_memories_heading')}</span>
                </h2>
                <p className="text-xs text-fg-secondary">{t('pod.meta.personal_memories_subheading')}</p>
              </div>
              <Badge variant="secondary" className="tabular-nums">
                {personalClaims.length}
              </Badge>
            </div>
            {personalClaims.length === 0 ? (
              <p className="py-4 text-xs text-fg-tertiary">{t('pod.meta.no_personal_memories')}</p>
            ) : (
              <ul className="space-y-2">
                {personalClaims.map(claim => (
                  <BrainClaimRow key={claim.id} claim={claim} />
                ))}
              </ul>
            )}
          </section>

          <section className="space-y-3 rounded-control border border-border p-4">
            <div className="flex items-start justify-between gap-2">
              <div className="space-y-0.5">
                <h2 className="flex items-center gap-1.5 text-sm font-semibold text-fg-primary">
                  <BuildingRegular aria-hidden className="size-4 text-fg-secondary" />
                  <span>{t('pod.meta.workspace_context_heading')}</span>
                </h2>
                <p className="text-xs text-fg-secondary">{t('pod.meta.workspace_context_subheading')}</p>
              </div>
              <Badge variant="outline" className="tabular-nums">
                {workspaceClaims.length}
              </Badge>
            </div>
            {workspaceClaims.length === 0 ? (
              <p className="py-4 text-xs text-fg-tertiary">{t('pod.meta.no_workspace_context')}</p>
            ) : (
              <ul className="space-y-2">
                {workspaceClaims.map(claim => (
                  <BrainClaimRow key={claim.id} claim={claim} />
                ))}
              </ul>
            )}
          </section>
        </div>
      )}
    </div>
  )
}
