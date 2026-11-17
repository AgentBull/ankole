import { Badge, Button, ScrollFade, Spinner } from '@ankole/uikit'
import { DocumentAddRegular, LockClosedRegular, TaskListSquareLtrRegular } from '@ankole/uikit/icons'
import { useInfiniteQuery, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { browserSession } from '../../common/api/generated/sdk.gen'
import { stripBidi } from '../../common/bidi'
import { BdiLabel } from '../../common/bidi-file-name'
import { podID, podLocation, sessionIdentityKey } from '../../common/browser-context'
import { formatRelativeTime } from '../../common/date-time'
import { conversationAttentionQuery, podKeys, type PodAgent } from '../api'
import { podConversations } from '../api/generated/sdk.gen'
import {
  commentAttentionQuery,
  contentKeys,
  directoryCapabilitiesQuery,
  pagesByID,
  pagesQuery,
  type Page,
  type PageDetail
} from '../content-api'
import { ContentError, scopeLabels, typeLabels } from '../content-primitives'
import { jobsSummaryQuery } from '../jobs-api'
import { usePageCreation } from '../page-create-menu'
import { PageIcon } from '../page-icon'
import { extractDocumentPreviewSnippet, PageBodyMiniature, pagePreviewWash } from '../page-sharing/share-preview'
import { mergeRecentEntries } from '../state/navigation'
import { pagePathAncestors } from '../state/page-location'
import { usePageHref, usePagesMetadata } from '../use-page-metadata'
import { ChatAvatar } from './chat-avatar'
import {
  ChatRowStatus,
  ConversationGlyph,
  ConversationTitle,
  conversationLabel,
  conversationPath,
  conversationPreview,
  type RoomRow
} from './conversation-row'
import { NextStepsMenu } from './next-steps-menu'

function HomePageCard({
  page,
  timestamp,
  knownPages
}: {
  page: Page
  timestamp?: string
  knownPages: ReadonlyMap<string, Page>
}) {
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const pageHref = usePageHref()
  const cachedDetail = client.getQueryData<PageDetail>(contentKeys.page(page.id))
  const snippet =
    page.type === 'doc' || page.type === 'knowledge'
      ? extractDocumentPreviewSnippet(cachedDetail?.content?.content)
      : null
  const ancestors = pagePathAncestors(page, knownPages)
  const parentName = ancestors.at(-1) ? stripBidi(ancestors.at(-1)!.title) || t('pod.content.untitled') : ''
  const locationLabel = page.private_owner_uid ? t('pod.content.private') : parentName || scopeLabels.space
  const relative = timestamp ? formatRelativeTime(timestamp, i18n.language) : ''
  const metaLine = [relative, locationLabel].filter(Boolean).join(' · ')
  const displayTitle = page.title.trim()
  const accessibleTitle = displayTitle || t('pod.content.untitled')

  return (
    <li className="w-52 shrink-0 snap-start">
      <Link
        to={pageHref(page.id, page.title)}
        aria-label={accessibleTitle}
        aria-description={[typeLabels[page.type], metaLine].filter(Boolean).join(' · ')}
        className="pod-home-card-link">
        <article className="pod-home-card">
          <div aria-hidden className="h-6 w-full shrink-0" style={{ background: pagePreviewWash(page.id) }} />
          <div className="flex min-h-0 flex-1 flex-col px-3 pt-1 pb-2.5">
            <div className="-mt-3.5 mb-1.5 flex items-end justify-between gap-1.5">
              <span
                aria-hidden
                className="flex size-6.5 shrink-0 items-center justify-center rounded-control border border-border-subtle/70 bg-page text-sm shadow-2xs [&_.pod-page-icon]:size-4">
                <PageIcon page={page} />
              </span>
              {page.private_owner_uid && <LockClosedRegular aria-hidden className="mb-0.5 size-3 text-fg-tertiary" />}
            </div>
            <div
              className={
                displayTitle
                  ? 'truncate text-65 leading-4.5 font-medium text-fg-primary'
                  : 'truncate text-65 leading-4.5 font-medium text-fg-tertiary'
              }>
              <BdiLabel value={displayTitle} fallback={t('pod.content.untitled')} />
            </div>
            <PageBodyMiniature type={page.type} fileName={page.name || displayTitle} snippet={snippet} />
            {metaLine && <p className="m-0 mt-auto truncate pt-2 text-50 leading-4 text-fg-tertiary">{metaLine}</p>}
          </div>
        </article>
      </Link>
    </li>
  )
}

function HomeConversationCard({ room, timestamp }: { room: RoomRow; timestamp?: string }) {
  const { t, i18n } = useTranslation()
  const relative = timestamp ? formatRelativeTime(timestamp, i18n.language) : ''
  const chatLabel = t('pod.sidebar.tabs.chat')
  const metaLine = [relative, chatLabel].filter(Boolean).join(' · ')
  const preview =
    conversationPreview(room.latestMessagePreview) ||
    (room.conversationKind === 'colleague_dm'
      ? room.agents[0]?.role
      : room.agents.map(agent => agent.displayName).join(', '))

  return (
    <li className="w-52 shrink-0 snap-start">
      <Link
        to={conversationPath(room)}
        state={{ keepSidebarTab: 'home' } as never}
        aria-label={conversationLabel(room, t('pod.content.untitled'))}
        aria-description={[preview, metaLine].filter(Boolean).join(' · ')}
        className="pod-home-card-link">
        <article className="pod-home-card">
          <div aria-hidden className="h-6 w-full shrink-0" style={{ background: pagePreviewWash(room.id) }} />
          <div className="flex min-h-0 flex-1 flex-col px-3 pt-1 pb-2.5">
            <div className="-mt-3.5 mb-1.5 flex items-end justify-between gap-1.5">
              <span
                aria-hidden
                className="flex size-6.5 shrink-0 items-center justify-center rounded-control border border-border-subtle/70 bg-page text-sm shadow-2xs">
                <ConversationGlyph room={room} size="sm" />
              </span>
              {room.rowStatus !== 'idle' && (
                <span className="mb-0.5 shrink-0">
                  <ChatRowStatus status={room.rowStatus} />
                </span>
              )}
            </div>
            <div className="truncate text-65 leading-4.5 font-medium text-fg-primary" dir="auto">
              <ConversationTitle room={room} />
            </div>
            {preview ? (
              <p className="m-0 mt-1.5 line-clamp-2 text-50 leading-4 text-fg-secondary">{preview}</p>
            ) : (
              <div aria-hidden className="mt-2 grid gap-1.25">
                <span className="h-1.25 w-4/5 rounded-full bg-fg-primary/[0.08]" />
                <span className="h-1.25 w-1/2 rounded-full bg-fg-primary/[0.08]" />
              </div>
            )}
            {metaLine && <p className="m-0 mt-auto truncate pt-2 text-50 leading-4 text-fg-tertiary">{metaLine}</p>}
          </div>
        </article>
      </Link>
    </li>
  )
}

export function ChatHomeView({
  composer,
  onSuggestion,
  showSuggestions,
  assistantAvailable = true,
  pageID,
  colleague,
  children
}: {
  composer: ReactNode
  onSuggestion(text: string): void
  showSuggestions: boolean
  assistantAvailable?: boolean
  pageID?: string
  colleague?: PodAgent
  children?: ReactNode
}) {
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const pageHref = usePageHref()
  const standalone = !pageID && !colleague

  const session = useQuery({
    queryKey: ['pod-session', sessionIdentityKey() ?? '', podID() ?? ''],
    queryFn: () => browserSession()
  })
  const destinations = useInfiniteQuery({
    ...directoryCapabilitiesQuery(),
    enabled: standalone
  })
  const capabilities = destinations.data
  const createScope = capabilities?.can_create_space
    ? 'space'
    : capabilities?.can_create_private && capabilities.principal_uid
      ? 'private'
      : undefined
  const canCreateDoc = standalone && !destinations.isError && Boolean(createScope)
  const createDoc = usePageCreation({
    scope: createScope ?? 'space',
    privateOwner: capabilities?.principal_uid
  })

  const attention = useQuery({
    ...conversationAttentionQuery,
    enabled: standalone
  })
  const commentAttention = useQuery({
    ...commentAttentionQuery,
    enabled: standalone
  })
  const jobsSummary = useQuery({
    ...jobsSummaryQuery,
    enabled: standalone
  })
  const recentPages = useQuery({
    ...pagesQuery('recent'),
    enabled: standalone
  })
  const recentRooms = useQuery({
    queryKey: [...podKeys.conversations, 'recent'],
    queryFn: ({ signal }) => podConversations({ query: { order: 'recent', limit: 8 }, signal }),
    enabled: standalone
  })
  const favoritesQuery = useQuery({
    ...pagesQuery('favorites'),
    enabled: standalone
  })

  const needsInput = (attention.data ?? []).filter(room => room.rowStatus === 'waiting_choice')
  const needsInputIDs = new Set(needsInput.map(room => room.id))
  const unreadCommentRows = (commentAttention.data ?? []).filter(row => row.unread_count > 0)
  const unreadCommentPages = usePagesMetadata(unreadCommentRows.map(row => row.page))
  const jobsAttention = jobsSummary.data?.attentionCount ?? 0
  const attentionTotal = needsInput.length + unreadCommentRows.length + jobsAttention

  const hydratedRecentPages = usePagesMetadata(recentPages.data?.pages ?? [])
  const favoritePages = usePagesMetadata(favoritesQuery.data?.pages ?? []).slice(0, 8)
  const unreadByPage = new Map(unreadCommentRows.map(row => [row.page.id, row.unread_count]))
  const jumpEntries = mergeRecentEntries(
    hydratedRecentPages.map(page => ({ ...page, relevantUnread: unreadByPage.get(page.id) ?? 0 })),
    (recentRooms.data?.conversations ?? []).filter(room => !needsInputIDs.has(room.id))
  ).slice(0, 8)
  const attentionError = attention.error || commentAttention.error || jobsSummary.error
  const recentError = recentPages.error || recentRooms.error
  const favoritesError = favoritesQuery.error
  const knownPages = pagesByID(client, [...hydratedRecentPages, ...favoritePages])

  return (
    <div className="pod-chat-home">
      <div className="pod-chat-home-main">
        {colleague ? (
          // A colleague the user has not written to yet introduces itself by name, handle, and responsibility.
          <div className="pod-chat-colleague-intro">
            <ChatAvatar name={colleague.displayName} src={colleague.avatarURL} agent />
            <h1>{colleague.displayName}</h1>
            <p className="pod-chat-colleague-uid">@{colleague.uid}</p>
          </div>
        ) : (
          !pageID && (
            <>
              <p className="pod-chat-home-eyebrow">{t('pod.chat_room.workspace')}</p>
              <h1>{t('pod.chat_room.greeting', { name: session.data?.displayName || t('pod.chat_room.team') })}</h1>
            </>
          )
        )}
        <div className="pod-chat-home-lead">
          <p className="pod-chat-home-subtitle">
            {colleague
              ? colleague.role || t('pod.superagent.dm_no_role')
              : pageID
                ? t('pod.page_chat.start_hint')
                : assistantAvailable
                  ? t('pod.chat_room.home_hint')
                  : t('pod.superagent.choose_colleague')}
          </p>
          {canCreateDoc && (
            <Button
              variant="outline"
              size="sm"
              data-slot="home-new-document"
              aria-busy={createDoc.isPending}
              disabled={createDoc.isPending}
              onClick={() => void createDoc.submit('doc')}>
              {createDoc.isPending ? (
                <Spinner aria-hidden className="size-4" />
              ) : (
                <DocumentAddRegular aria-hidden className="size-4" />
              )}
              {createDoc.isPending ? t('pod.content.creating') : t('pod.chat_room.new_document')}
            </Button>
          )}
        </div>
        {children}
        {composer}
      </div>
      {standalone && (
        <div className="pod-chat-home-guides">
          {(attentionTotal > 0 || Boolean(attentionError)) && (
            <section data-slot="home-needs-attention" className="pod-home-span-full">
              <h2>
                {attentionTotal > 0
                  ? `${t('pod.chat_room.section_needs_input')} (${attentionTotal})`
                  : t('pod.chat_room.section_needs_input')}
              </h2>
              <ContentError
                error={attentionError}
                retry={() => {
                  void attention.refetch()
                  void commentAttention.refetch()
                  void jobsSummary.refetch()
                }}
              />
              {needsInput.map(room => (
                <Link
                  key={`chat:${room.id}`}
                  className="pod-chat-recent-row"
                  state={{ keepSidebarTab: 'home' } as never}
                  to={conversationPath(room)}>
                  <ConversationGlyph room={room} size="md" />
                  <span className="pod-chat-recent-copy">
                    <span className="pod-chat-recent-title">
                      <ConversationTitle room={room} />
                    </span>
                    <span className="pod-chat-subtle flex items-center gap-1.5">
                      <ChatRowStatus status={room.rowStatus} />
                      <span>{formatRelativeTime(room.lastActivityAt, i18n.language)}</span>
                    </span>
                  </span>
                </Link>
              ))}
              {unreadCommentRows.map((row, idx) => {
                const page = unreadCommentPages[idx] ?? row.page
                return (
                  <Link key={`comment:${page.id}`} className="pod-chat-recent-row" to={pageHref(page.id, page.title)}>
                    <span className="flex size-5 shrink-0 items-center justify-center">
                      <PageIcon page={page} />
                    </span>
                    <span className="pod-chat-recent-copy">
                      <span className="pod-chat-recent-title">
                        <BdiLabel value={page.title} fallback={t('pod.content.untitled')} />
                      </span>
                      <span className="pod-chat-subtle flex items-center gap-1.5">
                        <Badge variant="info" size="sm" title={t('pod.document.unread_comments')}>
                          {row.unread_count}
                        </Badge>
                        <span>{formatRelativeTime(row.activity_at, i18n.language)}</span>
                      </span>
                    </span>
                  </Link>
                )
              })}
              {jobsAttention > 0 && (
                <Link className="pod-chat-recent-row" to={podLocation('/jobs').pathname}>
                  <span className="flex size-5 shrink-0 items-center justify-center text-fg-secondary">
                    <TaskListSquareLtrRegular aria-hidden className="size-4" />
                  </span>
                  <span className="pod-chat-recent-copy">
                    <span className="pod-chat-recent-title">{t('pod.jobs.title')}</span>
                    <span className="pod-chat-subtle flex items-center gap-1.5">
                      <Badge variant="warning" size="sm">
                        {jobsAttention}
                      </Badge>
                    </span>
                  </span>
                </Link>
              )}
            </section>
          )}
          {showSuggestions && assistantAvailable && (
            <NextStepsMenu
              onChoose={onSuggestion}
              fallback={
                <section className="pod-home-span-full">
                  <h2>{t('pod.chat_room.start_with')}</h2>
                  <div className="pod-chat-starters">
                    {['research', 'analyze', 'build', 'notes'].map(key => (
                      <button type="button" key={key} onClick={() => onSuggestion(t(`pod.chat_room.starter_${key}`))}>
                        {t(`pod.chat_room.starter_${key}`)}
                      </button>
                    ))}
                  </div>
                </section>
              }
            />
          )}
          {(jumpEntries.length > 0 || Boolean(recentError)) && (
            <section data-slot="home-jump-back-in" className="pod-home-span-full">
              <div className="pod-home-section-header">
                <h2>{t('pod.chat_room.recent')}</h2>
                <Link to={podLocation('/content/recent').pathname} className="pod-home-section-more">
                  {t('pod.chat_room.view_all')} →
                </Link>
              </div>
              <ContentError
                error={recentError}
                retry={() => {
                  void recentPages.refetch()
                  void recentRooms.refetch()
                }}
              />
              {jumpEntries.length > 0 && (
                <ScrollFade
                  axis="x"
                  className="min-w-0 max-w-full"
                  render={<ul role="list" className="pod-home-card-strip" />}>
                  {jumpEntries.map(entry =>
                    entry.kind === 'page' ? (
                      <HomePageCard
                        key={`page:${entry.id}`}
                        page={entry.page}
                        timestamp={entry.timestamp}
                        knownPages={knownPages}
                      />
                    ) : (
                      <HomeConversationCard key={`chat:${entry.id}`} room={entry.room} timestamp={entry.timestamp} />
                    )
                  )}
                </ScrollFade>
              )}
            </section>
          )}
          {(favoritePages.length > 0 || Boolean(favoritesError)) && (
            <section data-slot="home-favorites" className="pod-home-span-full">
              <div className="pod-home-section-header">
                <h2>{scopeLabels.favorites}</h2>
                <Link to={podLocation('/content/favorites').pathname} className="pod-home-section-more">
                  {t('pod.chat_room.view_all')} →
                </Link>
              </div>
              <ContentError error={favoritesError} retry={() => void favoritesQuery.refetch()} />
              {favoritePages.length > 0 && (
                <ScrollFade
                  axis="x"
                  className="min-w-0 max-w-full"
                  render={<ul role="list" className="pod-home-card-strip" />}>
                  {favoritePages.map(page => (
                    <HomePageCard
                      key={page.id}
                      page={page}
                      timestamp={page.visited_at ?? page.updated_at}
                      knownPages={knownPages}
                    />
                  ))}
                </ScrollFade>
              )}
            </section>
          )}
        </div>
      )}
    </div>
  )
}
