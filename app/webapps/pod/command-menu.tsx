import { createContext, useContext, useDeferredValue, useEffect, useRef, useState, type RefObject } from 'react'
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  Dialog,
  DialogContent,
  DialogTitle,
  useSidebar
} from '@ankole/uikit'
import { RiAddLine, RiChat3Line, RiSearchLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useNavigate } from '@tanstack/react-router'
import { podLocation } from '../common/browser-context'
import { conversationsQuery } from './api'
import { pageSearchQuery } from './content-api'
import { ContentError, typeLabels } from './content-primitives'
import { scopeIcons, scopeLabels } from './page-navigation'
import { PageIcon } from './page-icon'

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
  const conversations = useQuery({ ...conversationsQuery, enabled: open })
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
              {(['all', 'space', 'private', 'shared', 'recent', 'favorites', 'trash'] as const)
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
            </CommandGroup>
            <CommandGroup heading={t('pod.content.all_pages')}>
              {pageResults.map(page => {
                const title = page.title || t('pod.content.untitled')
                return (
                  <CommandItem
                    key={page.id}
                    value={`page:${page.id}`}
                    keywords={[title, typeLabels[page.type]]}
                    onSelect={() => void choose(`/pages/${page.id}`)}>
                    <PageIcon page={page} />
                    <span className="min-w-0 flex-1 truncate">{title}</span>
                    <span className="shrink-0 text-xs text-fg-tertiary">{typeLabels[page.type]}</span>
                  </CommandItem>
                )
              })}
            </CommandGroup>
            <CommandGroup heading={t('pod.sidebar.tabs.chat')}>
              {conversations.data?.conversations.map(conversation => (
                <CommandItem
                  key={conversation.id}
                  value={`chat:${conversation.id}`}
                  keywords={[conversation.title]}
                  onSelect={() => void choose(`/conversations/${conversation.id}`)}>
                  <RiChat3Line aria-hidden />
                  <span className="truncate">{conversation.title}</span>
                </CommandItem>
              ))}
            </CommandGroup>
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
