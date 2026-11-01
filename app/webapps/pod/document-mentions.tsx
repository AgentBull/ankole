import { formatFileBytes } from '../common/file-format'
import { usePageMetadata } from './use-page-metadata'
import { pageMetadata } from './state/page-metadata'
import {
  Badge,
  Button,
  HoverCard,
  HoverCardContent,
  HoverCardTrigger,
  Popover,
  PopoverContent,
  PopoverTrigger,
  Tooltip,
  TooltipContent,
  TooltipTrigger,
  cn
} from '@ankole/uikit'
import type { EditorHost, MentionItem, MentionTarget } from '@ankole/block-editor/editor'
import { useSignals } from '@preact/signals-react/runtime'
import { RiCheckLine, RiFileCopyLine, RiLockLine, RiRobot2Line } from '@remixicon/react'
import { QueryClientProvider, type QueryClient } from '@tanstack/react-query'
import type { i18n as I18nInstance } from 'i18next'
import { useEffect, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { I18nextProvider, useTranslation } from 'react-i18next'
import { principalUID } from '../common/browser-context'
import { rootErrorOptions } from '../common/error-boundary'
import { avatarInitials } from './avatar-initials'
import { pageAPI, type Page } from './content-api'
import { typeLabels } from './content-primitives'
import { PageIcon } from './page-icon'
import { peerColor } from './state/document-presence'
import {
  matchPodPageUrl,
  mentionPlainText,
  mentionStore,
  type MentionStore,
  type PageCandidate
} from './state/document-mentions'

function formatRelativeTime(iso: string | null | undefined, locale: string): string {
  if (!iso) return ''
  const timestamp = Date.parse(iso)
  if (Number.isNaN(timestamp)) return ''
  const diffSeconds = Math.round((timestamp - Date.now()) / 1000)
  const absSeconds = Math.abs(diffSeconds)
  try {
    const rtf = new Intl.RelativeTimeFormat(locale, { numeric: 'auto' })
    if (absSeconds < 60) return rtf.format(diffSeconds, 'second')
    const diffMinutes = Math.round(diffSeconds / 60)
    if (Math.abs(diffMinutes) < 60) return rtf.format(diffMinutes, 'minute')
    const diffHours = Math.round(diffMinutes / 60)
    if (Math.abs(diffHours) < 24) return rtf.format(diffHours, 'hour')
    const diffDays = Math.round(diffHours / 24)
    if (Math.abs(diffDays) < 7) return rtf.format(diffDays, 'day')
    const date = new Date(timestamp)
    const sameYear = date.getFullYear() === new Date().getFullYear()
    return new Intl.DateTimeFormat(locale, {
      month: 'short',
      day: 'numeric',
      ...(sameYear ? {} : { year: 'numeric' })
    }).format(date)
  } catch {
    return iso.slice(0, 10)
  }
}

function pageLocationPath(
  page: {
    private_owner_uid?: string | null
    ancestors?: readonly string[] | null
  },
  spaceName: string,
  t: (key: string) => string
): string {
  const rootLabel = page.private_owner_uid ? t('pod.content.private') : spaceName || t('pod.content.space')
  const parents = (page.ancestors ?? []).map(title => title.trim() || t('pod.content.untitled'))
  return [rootLabel, ...parents].join(' / ')
}

function PrincipalAvatar({
  uid,
  name,
  avatarUrl,
  isAgent,
  disabled,
  className
}: {
  uid: string
  name: string
  avatarUrl?: string | null
  isAgent?: boolean
  disabled?: boolean
  className?: string
}) {
  const [failed, setFailed] = useState(false)
  const initial = avatarInitials(name)
  const shape = isAgent ? 'rounded-[6px]' : 'rounded-full'
  if (avatarUrl && !failed) {
    return (
      <img
        src={avatarUrl}
        alt=""
        draggable={false}
        onError={() => setFailed(true)}
        className={cn('aspect-square shrink-0 object-cover', shape, disabled && 'grayscale opacity-70', className)}
      />
    )
  }
  return (
    <span
      aria-hidden
      style={disabled ? undefined : { color: peerColor(uid) }}
      className={cn(
        'inline-flex shrink-0 items-center justify-center bg-muted font-semibold leading-none select-none',
        shape,
        disabled && 'text-fg-tertiary',
        className
      )}>
      {isAgent ? <RiRobot2Line className="size-[62%]" /> : initial}
    </span>
  )
}

function InlinePageMention({
  id,
  store,
  currentPageID,
  pageHref,
  openPage
}: {
  id: string
  store: MentionStore
  currentPageID?: string
  pageHref: (id: string) => string
  openPage?: (id: string) => void
}) {
  useSignals()
  const { t, i18n } = useTranslation()
  useEffect(() => store.observePage(id, currentPageID), [store, id, currentPageID])
  const snapshot = store.pageSignal(id).value
  const resolved = usePageMetadata(snapshot?.access === 'restricted' ? undefined : snapshot) ?? snapshot
  const spaceName = store.spaceName.value

  if (!resolved) {
    return <span className="pod-mention-skeleton" aria-busy="true" />
  }

  if (resolved.access === 'restricted') {
    return (
      <Tooltip>
        <TooltipTrigger
          render={<span className="pod-mention-page pod-mention-restricted" data-mention-access="restricted" />}>
          <RiLockLine aria-hidden className="pod-mention-page-icon" />
          <span>{t('pod.mention.restricted_page')}</span>
        </TooltipTrigger>
        <TooltipContent>{t('pod.mention.restricted_page_hint')}</TooltipContent>
      </Tooltip>
    )
  }

  const pageType = (resolved.type ?? 'doc') as Page['type']
  const title = (resolved.title ?? '').trim() || t('pod.content.untitled')
  const trashed = resolved.access === 'trashed'
  const href = pageHref(id)
  const pathLabel = pageLocationPath(resolved, spaceName, key => t(key))
  const updatedLabel = formatRelativeTime(resolved.updated_at, i18n.language)
  const fileSummary =
    pageType === 'file' && resolved.file
      ? [resolved.file.content_type ?? '', formatFileBytes(resolved.file.size)].filter(Boolean).join(' · ')
      : ''

  return (
    <HoverCard>
      <HoverCardTrigger
        href={href}
        delay={250}
        closeDelay={150}
        data-mention-access={resolved.access}
        className={cn('pod-mention-page', trashed && 'pod-mention-trashed')}
        onClick={event => {
          if (event.defaultPrevented || event.button !== 0) return
          if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
          if (openPage) {
            event.preventDefault()
            openPage(id)
          }
        }}>
        <PageIcon page={{ type: pageType, icon: resolved.icon ?? null }} className="pod-mention-page-icon" />
        <span>{title}</span>
      </HoverCardTrigger>
      <HoverCardContent align="start" sideOffset={6} className="w-80 space-y-2 p-3.5" aria-label={title}>
        <div className="flex items-start gap-2">
          <PageIcon page={{ type: pageType, icon: resolved.icon ?? null }} className="mt-0.5 size-4.5 shrink-0" />
          <span className="line-clamp-2 min-w-0 flex-1 font-medium leading-snug text-foreground">{title}</span>
          {trashed && <Badge variant="warning">{t('pod.mention.trashed_badge')}</Badge>}
        </div>
        {pathLabel && <p className="truncate text-xs text-fg-tertiary">{pathLabel}</p>}
        {resolved.excerpt ? (
          <p className="line-clamp-3 text-xs leading-relaxed text-fg-secondary">{resolved.excerpt}</p>
        ) : fileSummary ? (
          <p className="truncate text-xs text-fg-secondary">{fileSummary}</p>
        ) : pageType !== 'doc' ? (
          <p className="text-xs text-fg-secondary">{typeLabels[pageType]}</p>
        ) : null}
        {updatedLabel && (
          <p className="text-xs text-fg-tertiary">{t('pod.mention.updated_at', { time: updatedLabel })}</p>
        )}
      </HoverCardContent>
    </HoverCard>
  )
}

function InlinePrincipalMention({
  uid,
  store,
  currentPageID
}: {
  uid: string
  store: MentionStore
  currentPageID?: string
}) {
  useSignals()
  const { t } = useTranslation()
  const [copied, setCopied] = useState(false)
  const copiedTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => store.observePrincipal(uid, currentPageID), [store, uid, currentPageID])
  useEffect(
    () => () => {
      if (copiedTimer.current !== null) clearTimeout(copiedTimer.current)
    },
    []
  )
  const resolved = store.principalSignal(uid, currentPageID).value

  if (!resolved) {
    return <span className="pod-mention-skeleton" aria-busy="true" />
  }

  if (resolved.access === 'restricted') {
    return (
      <span className="pod-mention-principal pod-mention-restricted" data-mention-access="restricted">
        <RiLockLine aria-hidden className="pod-mention-principal-lock" />
        <span>@{t('pod.mention.restricted_principal')}</span>
      </span>
    )
  }

  const currentUID = principalUID()
  const isSelf = Boolean(currentUID && uid === currentUID)
  const disabled = resolved.access === 'disabled'
  const isAgent = resolved.kind === 'agent'
  const displayName = (resolved.name ?? '').trim() || uid
  const copyValue = isAgent ? (resolved.principal_uid ? `@${resolved.principal_uid}` : '') : (resolved.email ?? '')

  const copyContact = async () => {
    if (!copyValue || typeof navigator === 'undefined' || !navigator.clipboard?.writeText) return
    try {
      await navigator.clipboard.writeText(copyValue)
      setCopied(true)
      if (copiedTimer.current !== null) clearTimeout(copiedTimer.current)
      copiedTimer.current = setTimeout(() => {
        copiedTimer.current = null
        setCopied(false)
      }, 1500)
    } catch {
      // Ignore denied clipboard permissions in non-secure contexts.
    }
  }

  return (
    <Popover>
      <PopoverTrigger
        type="button"
        data-mention-access={resolved.access}
        data-mention-self={isSelf ? 'true' : undefined}
        className={cn('pod-mention-principal', isSelf && 'pod-mention-self', disabled && 'pod-mention-disabled')}>
        <PrincipalAvatar
          uid={uid}
          name={displayName}
          avatarUrl={resolved.avatar_url}
          isAgent={isAgent}
          disabled={disabled}
          className="pod-mention-principal-avatar"
        />
        <span>{displayName}</span>
      </PopoverTrigger>
      <PopoverContent align="start" sideOffset={6} className="w-70 gap-3 p-3.5" aria-label={displayName}>
        <div className="flex items-center gap-2.5">
          <PrincipalAvatar
            uid={uid}
            name={displayName}
            avatarUrl={resolved.avatar_url}
            isAgent={isAgent}
            disabled={disabled}
            className="size-9 text-sm"
          />
          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-center gap-1.5">
              <span className="truncate font-medium text-foreground">{displayName}</span>
              <Badge variant="secondary">
                {isAgent
                  ? t('pod.mention.agent_role')
                  : resolved.membership === 'guest'
                    ? t('pod.mention.guest_badge')
                    : t('pod.mention.member_badge')}
              </Badge>
              {disabled && <Badge variant="outline">{t('pod.mention.disabled_badge')}</Badge>}
            </div>
            {isAgent
              ? resolved.principal_uid && <p className="truncate text-xs text-fg-tertiary">@{resolved.principal_uid}</p>
              : resolved.job_title && <p className="truncate text-xs text-fg-secondary">{resolved.job_title}</p>}
          </div>
        </div>
        {isAgent
          ? resolved.role && <p className="line-clamp-3 text-xs leading-relaxed text-fg-secondary">{resolved.role}</p>
          : resolved.email && <p className="truncate text-xs text-fg-tertiary">{resolved.email}</p>}
        {copyValue && (
          <div>
            <Button type="button" variant="outline" size="xs" onClick={() => void copyContact()}>
              {copied ? <RiCheckLine aria-hidden /> : <RiFileCopyLine aria-hidden />}
              {copied ? t('pod.mention.copied') : t(isAgent ? 'pod.mention.copy_uid' : 'pod.mention.copy_email')}
            </Button>
          </div>
        )}
      </PopoverContent>
    </Popover>
  )
}

export function createMentionHostAdapters({
  client,
  currentPageID,
  pageHref,
  openPage,
  i18n,
  canQuery = true
}: {
  client: QueryClient
  currentPageID?: string
  pageHref: (id: string) => string
  openPage?: (id: string) => void
  i18n: I18nInstance
  canQuery?: boolean
}): Pick<EditorHost, 'mountMention' | 'queryMentions' | 'mentionText' | 'matchPageUrl'> {
  const store = mentionStore(client)

  return {
    mountMention: (target: MentionTarget, container: HTMLElement, options) => {
      const root = createRoot(container, rootErrorOptions)
      root.render(
        <I18nextProvider i18n={i18n}>
          <QueryClientProvider client={client}>
            {'page' in target ? (
              <InlinePageMention
                id={target.page}
                store={store}
                currentPageID={currentPageID}
                pageHref={pageHref}
                openPage={options.openPage ?? openPage}
              />
            ) : (
              <InlinePrincipalMention uid={target.principal} store={store} currentPageID={currentPageID} />
            )}
          </QueryClientProvider>
        </I18nextProvider>
      )
      return () => {
        queueMicrotask(() => root.unmount())
      }
    },
    ...(canQuery
      ? {
          queryMentions: async ({ query, category, signal }) => {
            const response = await pageMetadata(client).read(
              () => pageAPI.mentionCandidates(query, category, currentPageID, signal),
              result => result.pages
            )
            store.primeCandidates(response, currentPageID)
            const pagesByID = new Map<string, PageCandidate>(response.pages.map(page => [page.id, page]))
            const principalsByUID = new Map(response.principals.map(principal => [principal.principal_uid, principal]))
            const translate = (key: string) => i18n.t(key, { lng: i18n.language })
            const items: MentionItem[] = []

            const metaCollection = pageMetadata(client).collection
            const pageSection = category === 'all' ? translate('pod.editor.mention_tab_page') : undefined
            const principalSection = category === 'all' ? translate('pod.editor.mention_tab_principal') : undefined

            for (const entry of response.ranking) {
              if (entry.kind === 'page') {
                const candidate = pagesByID.get(entry.id)
                if (!candidate) continue
                const live = metaCollection.get(candidate.id)
                const rawTitle = live?.title ?? candidate.title
                const icon = live?.icon === undefined ? (candidate.icon ?? null) : live.icon
                const title = rawTitle.trim() || translate('pod.content.untitled')
                const pathLabel = pageLocationPath(candidate, response.space_name, translate)
                const relative = formatRelativeTime(candidate.updated_at, i18n.language)
                items.push({
                  target: { page: candidate.id },
                  title,
                  subtitle: [pathLabel, relative].filter(Boolean).join(' · '),
                  section: pageSection,
                  sectionCategory: pageSection ? 'page' : undefined,
                  icon: <PageIcon page={{ type: candidate.type, icon }} className="size-[18px] shrink-0" />
                })
              } else {
                const candidate = principalsByUID.get(entry.id)
                if (!candidate) continue
                const isAgent = candidate.kind === 'agent'
                const displayName = candidate.name.trim() || candidate.principal_uid
                const subtitle = isAgent
                  ? [`@${candidate.principal_uid}`, candidate.role ?? ''].filter(Boolean).join(' · ')
                  : [candidate.job_title ?? '', candidate.email ?? ''].filter(Boolean).join(' · ')
                items.push({
                  target: { principal: candidate.principal_uid },
                  title: displayName,
                  badge: isAgent
                    ? translate('pod.mention.agent_badge')
                    : candidate.membership === 'guest'
                      ? translate('pod.mention.guest_badge')
                      : undefined,
                  subtitle: subtitle || undefined,
                  section: principalSection,
                  sectionCategory: principalSection ? 'principal' : undefined,
                  icon: (
                    <PrincipalAvatar
                      uid={candidate.principal_uid}
                      name={displayName}
                      avatarUrl={candidate.avatar_url}
                      isAgent={isAgent}
                      className="size-7 text-xs"
                    />
                  )
                })
              }
            }

            return {
              items,
              totalAllMatches: response.total_all_matches
            }
          }
        }
      : {}),
    mentionText: target => mentionPlainText(client, target, currentPageID),
    matchPageUrl: url => matchPodPageUrl(url)
  }
}
