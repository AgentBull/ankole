import { createContext, useContext, useDeferredValue, useEffect, useRef, useState, type RefObject } from 'react'
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
import { RiAddLine, RiChat3Line, RiSearchLine, RiSettings3Line, RiUser3Line } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useNavigate } from '@tanstack/react-router'
import { browserSession } from '../common/api/generated/sdk.gen'
import { authenticationRef, podID, podLocation } from '../common/browser-context'
import { conversationSearchQuery } from './api'
import { pageSearchQuery } from './content-api'
import { ContentError, scopeIcons, scopeLabels, typeLabels } from './content-primitives'
import { PageIcon } from './page-icon'
import { pageAncestors } from './state/page-location'

export const PodCommandContext = createContext<(() => void) | null>(null)
export type PodCommandNavigationState = { focusComposer: true }

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
  const navigate = useNavigate()
  const { setOpenMobile } = useSidebar()
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const pages = useQuery({ ...pageSearchQuery(deferredQuery), enabled: open })
  const pageResults = query === deferredQuery ? (pages.data?.pages ?? []) : []
  const pagesByID = new Map([...pageResults, ...(pages.data?.ancestors ?? [])].map(page => [page.id, page]))
  const conversations = useQuery({ ...conversationSearchQuery(deferredQuery), enabled: open })
  const conversationResults = query === deferredQuery ? (conversations.data?.conversations ?? []) : []
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
  const choose = (path: string, newChat = false) => {
    selected.current = true
    setQuery('')
    onOpenChange(false)
    setOpenMobile(false)
    return navigate({
      to: podLocation(path).pathname,
      state: (newChat ? ({ focusComposer: true } satisfies PodCommandNavigationState) : undefined) as never
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
        <Command
          label={label}
          loop
          vimBindings={false}
          // Page and conversation results include body matches from the server; preserve higher scores for title and command matches.
          filter={(value, search, keywords) =>
            value.startsWith('page:') || value.startsWith('chat:')
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
            <CommandEmpty>{t('pod.content.no_matches')}</CommandEmpty>
            <CommandGroup heading={t('pod.content.page_navigation')}>
              <CommandItem
                value="new-chat"
                keywords={[t('pod.chat.new_conversation')]}
                onSelect={() => void choose('/', true)}>
                <RiAddLine aria-hidden />
                {t('pod.chat.new_conversation')}
              </CommandItem>
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
                  const parent = pageAncestors(page, pagesByID)
                    .map(page => page.title || t('pod.content.untitled'))
                    .join(' / ')
                  return (
                    <CommandItem
                      key={page.id}
                      value={`page:${page.id}`}
                      keywords={[title, typeLabels[page.type]]}
                      onSelect={() => void choose(`/pages/${page.id}`)}>
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
            {conversationResults.length > 0 && (
              <CommandGroup heading={t('pod.sidebar.tabs.chat')}>
                {conversationResults.map(conversation => {
                  const title = conversation.title.trim() || t('pod.content.untitled')
                  return (
                    <CommandItem
                      key={conversation.id}
                      value={`chat:${conversation.id}`}
                      keywords={[title]}
                      onSelect={() => void choose(`/conversations/${conversation.id}`)}>
                      <RiChat3Line aria-hidden />
                      <span className="truncate">{title}</span>
                    </CommandItem>
                  )
                })}
              </CommandGroup>
            )}
          </CommandList>
        </Command>
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
