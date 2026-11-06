import { usePageHref, usePagesMetadata } from './use-page-metadata'
import { createContext, useContext, useEffect, useRef, useState, type RefObject } from 'react'
import { useDebouncedValue } from '../common/use-debounced-value'
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  commandFilter,
  Dialog,
  DialogContent,
  DialogTitle,
  useSidebar
} from '@ankole/uikit'
import { RiAddLine, RiSearchLine, RiSettings3Line, RiUser3Line } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useNavigate } from '@tanstack/react-router'
import { browserSession } from '../common/api/generated/sdk.gen'
import { authenticationRef, podID } from '../common/browser-context'
import { podLocation } from '../common/pod-url'
import { ErrorBoundary } from '../common/error-boundary'
import { agentsQuery, conversationSearchQuery } from './api'
import { pageSearchQuery } from './content-api'
import { ContentError, scopeIcons, scopeLabels, typeLabels } from './content-primitives'
import { PageIcon } from './page-icon'
import { pagePathAncestors } from './state/page-location'
import { useChatDrafts } from './chat-drafts'
import { ChatAvatar } from './chat/chat-avatar'
import { AgentName, ConversationGlyph, ConversationTitle, conversationLabel } from './chat/conversation-row'

export const PodCommandContext = createContext<(() => void) | null>(null)
export type PodCommandNavigationState = {
  focusComposer?: true
  /** A chat result matched by message text opens its room at that message with the in-room find filled in. */
  findMessage?: { query: string; seq: number }
}

export function usePodCommandMenu() {
  const open = useContext(PodCommandContext)
  if (!open) throw new Error('Pod command menu provider is missing')
  return open
}

export function PodCommandMenu({
  open,
  onOpenChange,
  returnFocus
}: {
  open: boolean
  onOpenChange(open: boolean): void
  returnFocus: RefObject<HTMLElement | null>
}) {
  const { t } = useTranslation()
  const drafts = useChatDrafts()
  const navigate = useNavigate()
  const pageHref = usePageHref()
  const { setOpenMobile } = useSidebar()
  const [query, setQuery] = useState('')
  const settledQuery = useDebouncedValue(query, 180)
  const pages = useQuery({ ...pageSearchQuery(settledQuery), enabled: open })
  const pageResults = usePagesMetadata(query === settledQuery ? (pages.data?.pages ?? []) : [])
  const ancestors = usePagesMetadata(pages.data?.ancestors ?? [])
  const pagesByID = new Map([...pageResults, ...ancestors].map(page => [page.id, page]))
  const conversations = useQuery({ ...conversationSearchQuery(settledQuery), enabled: open })
  const agents = useQuery({ ...agentsQuery, enabled: open })
  const colleagueSearch = query.trim().replace(/^@/, '').toLocaleLowerCase()
  const colleagueResults = colleagueSearch
    ? (agents.data?.agents ?? []).filter(agent =>
        `${agent.uid} ${agent.displayName} ${agent.role ?? ''}`.toLocaleLowerCase().includes(colleagueSearch)
      )
    : []
  const conversationResults =
    query === settledQuery
      ? (conversations.data?.conversations ?? []).filter(
          conversation =>
            conversation.conversationKind !== 'colleague_dm' ||
            !colleagueResults.some(agent => agent.uid === conversation.agents[0]?.uid)
        )
      : []
  const session = useQuery({
    queryKey: ['pod-session', authenticationRef() ?? '', podID() ?? ''],
    queryFn: ({ signal }) => browserSession({ signal }),
    staleTime: 60_000,
    enabled: open
  })
  const selected = useRef(false)
  useEffect(() => {
    if (open) selected.current = false
  }, [open])
  const choose = (path: string, state?: PodCommandNavigationState) => {
    if (state?.focusComposer) drafts.startNew()
    selected.current = true
    setQuery('')
    onOpenChange(false)
    setOpenMobile(false)
    return navigate({
      to: podLocation(path).pathname,
      state: state as never
    })
  }
  const label = t('pod.command.open')
  return (
    <Dialog
      open={open}
      onOpenChange={next => {
        if (!next) setQuery('')
        onOpenChange(next)
      }}>
      <DialogContent
        className="pod-dialog-wide pod-command-dialog transition-none duration-0 data-starting-style:scale-100 data-starting-style:opacity-100 data-ending-style:scale-100 data-ending-style:opacity-100"
        showCloseButton={false}
        closeLabel={t('common.close')}
        finalFocus={() => {
          if (selected.current) return false
          if (returnFocus.current?.isConnected) return returnFocus.current
          return (
            [...document.querySelectorAll<HTMLElement>('[data-sidebar="trigger"]')].find(
              element => element.getClientRects().length > 0
            ) ?? null
          )
        }}>
        <DialogTitle className="sr-only">{label}</DialogTitle>
        <ErrorBoundary variant="panel" className="m-3" resetKeys={[open]}>
          <Command
            label={label}
            loop
            vimBindings={false}
            // Page and conversation results include body matches from the server; preserve higher scores for title and command matches.
            filter={(value, search, keywords) =>
              value.startsWith('page:') || value.startsWith('chat:') || value.startsWith('colleague:')
                ? Math.max(0.5, commandFilter(value, search, keywords))
                : commandFilter(value, search, keywords)
            }
            onKeyDownCapture={event => {
              if (event.key === 'Enter' && (event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229)) {
                event.stopPropagation()
              }
            }}>
            <CommandInput
              aria-label={label}
              placeholder={t('pod.command.placeholder')}
              value={query}
              onValueChange={setQuery}
              autoFocus
            />
            <CommandList label={label}>
              <CommandEmpty>
                {t(
                  query !== settledQuery || pages.isFetching || conversations.isFetching
                    ? 'pod.content.loading'
                    : 'pod.content.no_matches'
                )}
              </CommandEmpty>
              <CommandGroup heading={t('pod.content.page_navigation')}>
                {agents.data?.personalAssistantAvailable && (
                  <CommandItem
                    value="new-chat"
                    keywords={[t('pod.chat.new_conversation')]}
                    onSelect={() => void choose('/', { focusComposer: true })}>
                    <RiAddLine aria-hidden />
                    {t('pod.chat.new_conversation')}
                  </CommandItem>
                )}
                <CommandItem
                  value="scope:search"
                  keywords={[t('pod.content.search_pages')]}
                  onSelect={() => void choose('/content/search')}>
                  <RiSearchLine aria-hidden />
                  {t('pod.content.search_pages')}
                </CommandItem>
                {(['space', 'private', 'shared', 'recent', 'favorites', 'trash'] as const)
                  .filter(scope => scope !== 'private' || pages.data?.can_create_private !== false)
                  .map(scope => {
                    const Icon = scopeIcons[scope]
                    return (
                      <CommandItem
                        key={scope}
                        value={`scope:${scope}`}
                        keywords={[scopeLabels[scope]]}
                        onSelect={() => void choose(`/content/${scope}`)}>
                        <Icon aria-hidden />
                        {scopeLabels[scope]}
                      </CommandItem>
                    )
                  })}
                <CommandItem
                  value="nav:account-settings"
                  keywords={[t('pod.account.title')]}
                  onSelect={() => void choose('/me')}>
                  <RiUser3Line aria-hidden />
                  {t('pod.account.title')}
                </CommandItem>
                {session.data?.canManagePod && (
                  <CommandItem
                    value="nav:pod-settings"
                    keywords={[t('pod.settings.title')]}
                    onSelect={() => void choose('/settings')}>
                    <RiSettings3Line aria-hidden />
                    {t('pod.settings.title')}
                  </CommandItem>
                )}
              </CommandGroup>
              {pageResults.length > 0 && (
                <CommandGroup heading={t('pod.content.all_pages')}>
                  {pageResults.map(page => {
                    const title = page.title || t('pod.content.untitled')
                    const parent = pagePathAncestors(page, pagesByID)
                      .map(page => page.title || t('pod.content.untitled'))
                      .join(' / ')
                    return (
                      <CommandItem
                        key={page.id}
                        value={`page:${page.id}`}
                        keywords={[title, typeLabels[page.type]]}
                        onSelect={() => void choose(pageHref(page.id, page.title))}>
                        <PageIcon page={page} />
                        <span className="min-w-0 flex-1">
                          <span className="block truncate">{title}</span>
                          {parent && <span className="block truncate text-xs text-fg-tertiary">{parent}</span>}
                        </span>
                        <span className="shrink-0 text-xs text-fg-tertiary">{typeLabels[page.type]}</span>
                      </CommandItem>
                    )
                  })}
                </CommandGroup>
              )}
              {colleagueResults.length > 0 && (
                <CommandGroup heading={t('pod.superagent.messages_colleagues')}>
                  {colleagueResults.map(agent => (
                    <CommandItem
                      key={agent.uid}
                      value={`colleague:${agent.uid}`}
                      keywords={[agent.uid, agent.displayName, agent.role ?? '']}
                      onSelect={() => void choose(`/dm/${encodeURIComponent(agent.uid)}`)}>
                      <span className="pod-conversation-glyph">
                        <ChatAvatar name={agent.displayName} src={agent.avatarURL} agent />
                      </span>
                      <span className="min-w-0 flex-1">
                        <span className="block truncate">
                          <AgentName agent={agent} />
                        </span>
                        {agent.role && <span className="block truncate text-xs text-fg-tertiary">{agent.role}</span>}
                      </span>
                    </CommandItem>
                  ))}
                </CommandGroup>
              )}
              {conversationResults.length > 0 && (
                <CommandGroup heading={t('pod.sidebar.tabs.chat')}>
                  {conversationResults.map(conversation => {
                    const title = conversationLabel(conversation, t('pod.content.untitled'))
                    return (
                      <CommandItem
                        key={conversation.id}
                        value={`chat:${conversation.id}`}
                        keywords={[title]}
                        onSelect={() =>
                          void choose(
                            conversation.conversationKind === 'colleague_dm'
                              ? `/dm/${encodeURIComponent(conversation.agents[0]!.uid)}`
                              : `/conversations/${conversation.id}`,
                            conversation.searchMatch
                              ? { findMessage: { query: settledQuery.trim(), seq: conversation.searchMatch.seq } }
                              : undefined
                          )
                        }>
                        <ConversationGlyph room={conversation} />
                        <span className="min-w-0 flex-1">
                          <span className="block truncate">
                            <ConversationTitle room={conversation} />
                          </span>
                          {conversation.searchMatch && (
                            <span className="block truncate text-xs text-fg-tertiary">
                              {conversation.searchMatch.excerpt}
                            </span>
                          )}
                        </span>
                      </CommandItem>
                    )
                  })}
                </CommandGroup>
              )}
            </CommandList>
          </Command>
        </ErrorBoundary>
        {(pages.isPending || conversations.isPending) && (
          <p role="status" className="px-3 text-xs text-fg-tertiary">
            {t('pod.content.loading')}
          </p>
        )}
        <ContentError
          error={pages.error || conversations.error}
          retry={() => {
            void pages.refetch()
            void conversations.refetch()
          }}
        />
      </DialogContent>
    </Dialog>
  )
}
