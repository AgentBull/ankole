import { knownPageTitle, usePageHref, usePagesMetadata } from './use-page-metadata'
import {
  createContext,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type RefObject
} from 'react'
import { useDebouncedValue } from '../common/use-debounced-value'
import {
  Button,
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  CommandShortcut,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
  commandFilter,
  Dialog,
  DialogContent,
  DialogTitle,
  isCommandInteractiveTarget,
  Kbd,
  useSidebar
} from '@ankole/uikit'
import {
  AddRegular,
  ArrowUpRightRegular,
  BotRegular,
  BrainRegular,
  ChevronDownRegular,
  DismissRegular,
  HistoryRegular,
  PersonRegular,
  PlugConnectedRegular,
  PuzzlePieceRegular,
  SearchRegular,
  SettingsRegular
} from '@ankole/uikit/icons'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useLocation, useNavigate } from '@tanstack/react-router'
import { browserSession } from '../common/api/generated/sdk.gen'
import { authenticationRef, podID } from '../common/browser-context'
import { podLocation, podPagePathnameID } from '../common/pod-url'
import { isApplePlatform } from '../common/platform'
import { linkTarget } from '../common/router'
import { ErrorBoundary } from '../common/error-boundary'
import { agentsQuery, conversationSearchQuery } from './api'
import { metaSkillsQuery } from './meta-api'
import {
  cachedPageMap,
  cachedPages,
  contentKeys,
  pageAPI,
  pagesByID as mergePagesByID,
  pageSearchQuery,
  recentSearchesQuery,
  type Page,
  type PageSearchMatch,
  type PageSearchOptions,
  type PageSearchSort
} from './content-api'
import { ContentError, scopeIcons, scopeLabels, typeLabels, InlineLoading } from './content-primitives'
import { isImeComposingKey } from './find-bar'
import { PageIcon } from './page-icon'
import { HighlightedBdiLabel, HighlightedText, SearchSnippet } from './search-highlight'
import { buildSearchResultHref, formatSearchTargetBadge, normalizeSearchQuery } from './search-targets'
import { pageAncestors, pagePathAncestors } from './state/page-location'
import { pageMetadata } from './state/page-metadata'
import { useChatDrafts } from './chat-drafts'
import { ChatAvatar } from './chat/chat-avatar'
import { AgentName, ConversationGlyph, ConversationTitle, conversationLabel } from './chat/conversation-row'
import {
  CommandMenuPreview,
  type CommandChatEntry,
  type CommandColleagueEntry,
  type CommandEntry,
  type CommandNavigationEntry,
  type CommandPageEntry,
  type CommandRecentSearchEntry,
  type CommandSkillEntry
} from './command-menu-preview'

export const PodCommandContext = createContext<(() => void) | null>(null)
export type PodCommandNavigationState = {
  focusComposer?: true
  /** A chat result matched by message text opens its room at that message with the in-room find filled in. */
  findMessage?: { query: string; seq: number }
}

type CommandEntryGroup =
  | { kind: 'recent-search'; entries: CommandRecentSearchEntry[] }
  | { kind: 'page'; heading: string; entries: CommandPageEntry[] }
  | { kind: 'nav'; heading: string; entries: CommandNavigationEntry[] }
  | { kind: 'colleague'; heading: string; entries: CommandColleagueEntry[] }
  | { kind: 'skill'; heading: string; entries: CommandSkillEntry[] }
  | { kind: 'chat'; heading: string; entries: CommandChatEntry[] }

const shortcutCommands = ['new-chat', 'scope:search', 'scope:space', 'scope:private', 'scope:shared']

export function usePodCommandMenu() {
  const open = useContext(PodCommandContext)
  if (!open) throw new Error('Pod command menu provider is missing')
  return open
}

export function resolvePodTarget(href: string): { to: string; search?: Record<string, string>; url: string } {
  const qIndex = href.indexOf('?')
  const rawPathname = qIndex >= 0 ? href.slice(0, qIndex) : href
  const rawQuery = qIndex >= 0 ? Object.fromEntries(new URLSearchParams(href.slice(qIndex + 1))) : {}
  const loc = podLocation(rawPathname, rawQuery)
  const target = linkTarget(loc)
  return { ...target, url: `${loc.pathname}${loc.search}` }
}

function CommandHighlight() {
  const ref = useRef<HTMLSpanElement>(null)
  useLayoutEffect(() => {
    const highlight = ref.current
    const sizer = highlight?.parentElement
    if (!highlight || !sizer) return

    const place = () => {
      const row = sizer.querySelector<HTMLElement>('[cmdk-item][aria-selected="true"]')
      highlight.toggleAttribute('data-visible', row !== null)
      if (!row) return
      highlight.style.transform = `translateY(${row.offsetTop}px)`
      highlight.style.height = `${row.offsetHeight}px`
    }
    const selection = new MutationObserver(place)
    selection.observe(sizer, { subtree: true, childList: true, attributes: true, attributeFilter: ['aria-selected'] })
    const size = new ResizeObserver(place)
    size.observe(sizer)
    place()
    return () => {
      selection.disconnect()
      size.disconnect()
    }
  }, [])

  return <span ref={ref} aria-hidden className="pod-command-highlight" />
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
  const pathname = useLocation({ select: loc => loc.pathname })
  const { setOpenMobile } = useSidebar()

  const [query, setQuery] = useState('')
  const [titleOnly, setTitleOnly] = useState(false)
  const [sort, setSort] = useState<PageSearchSort>('best')
  const [inCurrentPage, setInCurrentPage] = useState(false)
  const [activeValue, setActiveValue] = useState('')
  const inputRef = useRef<HTMLInputElement>(null)
  const selected = useRef(false)

  useEffect(() => {
    if (open) selected.current = false
  }, [open])

  const resetMenuState = () => {
    setQuery('')
    setTitleOnly(false)
    setSort('best')
    setInCurrentPage(false)
    setActiveValue('')
  }

  const label = t('pod.command.open')

  return (
    <Dialog
      open={open}
      onOpenChange={(next, details) => {
        if (!next && details.reason === 'escape-key' && details.event.target === inputRef.current && query) {
          details.cancel()
          setQuery('')
          setActiveValue('')
          return
        }
        if (!next) resetMenuState()
        onOpenChange(next)
      }}>
      <DialogContent
        className="pod-dialog-wide pod-command-dialog pod-command-dialog-split transition-none duration-0 data-starting-style:scale-100 data-starting-style:opacity-100 data-ending-style:scale-100 data-ending-style:opacity-100"
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
        <PodCommandSurface
          open={open}
          pathname={pathname}
          query={query}
          onQueryChange={setQuery}
          titleOnly={titleOnly}
          onTitleOnlyChange={setTitleOnly}
          sort={sort}
          onSortChange={setSort}
          inCurrentPage={inCurrentPage}
          onInCurrentPageChange={setInCurrentPage}
          activeValue={activeValue}
          onActiveValueChange={setActiveValue}
          inputRef={inputRef}
          onSelectTarget={(href, state) => {
            if (state?.focusComposer) drafts.startNew()
            selected.current = true
            resetMenuState()
            onOpenChange(false)
            setOpenMobile(false)
            const target = resolvePodTarget(href)
            return navigate({
              to: target.to,
              ...(target.search ? { search: target.search as never } : {}),
              state: state as never
            })
          }}
          onOpenNewWindow={url => {
            window.open(url, '_blank', 'noopener,noreferrer')
            selected.current = true
            resetMenuState()
            onOpenChange(false)
            setOpenMobile(false)
          }}
        />
      </DialogContent>
    </Dialog>
  )
}

export function PodCommandSurface({
  open,
  pathname = '/',
  query,
  onQueryChange,
  titleOnly,
  onTitleOnlyChange,
  sort,
  onSortChange,
  inCurrentPage,
  onInCurrentPageChange,
  activeValue,
  onActiveValueChange,
  inputRef,
  onSelectTarget,
  onOpenNewWindow
}: {
  open: boolean
  pathname?: string
  query: string
  onQueryChange(next: string): void
  titleOnly: boolean
  onTitleOnlyChange: (next: boolean | ((prev: boolean) => boolean)) => void
  sort: PageSearchSort
  onSortChange(next: PageSearchSort): void
  inCurrentPage: boolean
  onInCurrentPageChange: (next: boolean | ((prev: boolean) => boolean)) => void
  activeValue: string
  onActiveValueChange(next: string): void
  inputRef: RefObject<HTMLInputElement | null>
  onSelectTarget(href: string, state?: PodCommandNavigationState): unknown
  onOpenNewWindow?(url: string): void
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const pageHref = usePageHref()
  const metadataStore = pageMetadata(client)
  const metadataRevision = useSyncExternalStore(
    listener => metadataStore.subscribe(listener),
    () => metadataStore.collection.size,
    () => 0
  )

  const currentPageID = useMemo(() => podPagePathnameID(pathname), [pathname])
  const currentPageTitle = currentPageID ? knownPageTitle(client, currentPageID) : undefined
  const scopePageID = inCurrentPage && currentPageID ? currentPageID : undefined

  const trimmedQuery = query.trim()
  const settledQuery = useDebouncedValue(query, 180)
  const effectiveLimit = settledQuery.trim() ? 30 : 8
  const searchOptions = useMemo<PageSearchOptions>(
    () => ({
      domain: 'all',
      title_only: titleOnly,
      sort,
      limit: effectiveLimit,
      ...(scopePageID ? { ancestor_id: scopePageID } : {})
    }),
    [effectiveLimit, titleOnly, sort, scopePageID]
  )

  const pages = useQuery({ ...pageSearchQuery(settledQuery, searchOptions), enabled: open })
  const recentSearches = useQuery({ ...recentSearchesQuery(8), enabled: open && !trimmedQuery })

  const deleteRecent = useMutation({
    mutationFn: (id: string) => pageAPI.deleteRecentSearch(id),
    onSuccess: () => client.invalidateQueries({ queryKey: contentKeys.recentSearches(8) })
  })
  const clearRecents = useMutation({
    mutationFn: () => pageAPI.clearRecentSearches(),
    onSuccess: () => client.invalidateQueries({ queryKey: contentKeys.recentSearches(8) })
  })

  const recordSearch = (raw: string, resultCount: number) => {
    const clean = raw.trim()
    if (clean.length < 2) return
    void pageAPI
      .recordRecentSearch(clean, resultCount)
      .then(() => client.invalidateQueries({ queryKey: contentKeys.recentSearches(8) }))
      .catch(() => {})
  }

  const serverReady = trimmedQuery === settledQuery.trim() && pages.data !== undefined
  const optimisticPages = useMemo<Page[]>(() => {
    void metadataRevision
    if (!open || !trimmedQuery || serverReady) return []
    const normalizedNeedle = normalizeSearchQuery(trimmedQuery)
    const knownMap = cachedPageMap(client)
    const candidates: Page[] = [...cachedPages(client)]
    if (!scopePageID) {
      for (const item of metadataStore.values()) {
        if (knownMap.has(item.id) || !item.title) continue
        const pageType: Page['type'] | undefined =
          item.type === 'doc' ||
          item.type === 'knowledge' ||
          item.type === 'base' ||
          item.type === 'applet' ||
          item.type === 'file'
            ? item.type
            : item.type === undefined
              ? 'doc'
              : undefined
        if (!pageType) continue
        candidates.push({
          id: item.id,
          name: item.id,
          title: item.title,
          icon: item.icon,
          type: pageType,
          inherit_permissions: true,
          metadata: {},
          updated_at: item.updated_at
        })
      }
    }
    return candidates
      .filter(page => {
        if (page.deleted_at || page.purge_started_at || page.is_root) return false
        if (page.system_key === 'ankole_brain_sources') return false
        const chain = pageAncestors(page, knownMap)
        if (chain.some(ancestor => ancestor.system_key === 'ankole_brain_sources')) return false
        if (scopePageID && !chain.some(ancestor => ancestor.id === scopePageID)) return false
        return normalizeSearchQuery(page.title ?? '').includes(normalizedNeedle)
      })
      .sort((a, b) => {
        const aTitle = normalizeSearchQuery(a.title ?? '')
        const bTitle = normalizeSearchQuery(b.title ?? '')
        const aExact = aTitle === normalizedNeedle ? 0 : aTitle.startsWith(normalizedNeedle) ? 1 : 2
        const bExact = bTitle === normalizedNeedle ? 0 : bTitle.startsWith(normalizedNeedle) ? 1 : 2
        if (aExact !== bExact) return aExact - bExact
        return (b.updated_at ?? '').localeCompare(a.updated_at ?? '')
      })
      .slice(0, 15)
  }, [client, metadataRevision, metadataStore, open, scopePageID, serverReady, trimmedQuery])

  const rawPageList = serverReady
    ? (pages.data?.pages ?? [])
    : trimmedQuery
      ? optimisticPages
      : (pages.data?.pages ?? [])
  const pageResults = usePagesMetadata(rawPageList)
  const ancestors = usePagesMetadata(pages.data?.ancestors ?? [])
  const pagesMap = mergePagesByID(client, [...pageResults, ...ancestors])
  const matchesByPageID = useMemo(() => {
    if (!serverReady) return new Map<string, PageSearchMatch>()
    return new Map((pages.data?.matches ?? []).map(match => [match.page_id, match]))
  }, [pages.data?.matches, serverReady])

  const conversations = useQuery({ ...conversationSearchQuery(settledQuery), enabled: open })
  const agents = useQuery({ ...agentsQuery, enabled: open })
  const skills = useQuery({ ...metaSkillsQuery(), enabled: open && Boolean(trimmedQuery) })
  const colleagueSearch = normalizeSearchQuery(trimmedQuery.replace(/^@/, ''))
  const colleagueResults = colleagueSearch
    ? (agents.data?.agents ?? []).filter(agent =>
        normalizeSearchQuery(`${agent.uid} ${agent.displayName} ${agent.role ?? ''}`).includes(colleagueSearch)
      )
    : []
  const skillSearch = normalizeSearchQuery(trimmedQuery.replace(/^\//, ''))
  const skillResults = skillSearch
    ? (skills.data?.skills ?? [])
        .filter(skill => normalizeSearchQuery(`${skill.name} ${skill.slug} ${skill.description}`).includes(skillSearch))
        .slice(0, 8)
    : []
  const conversationResults =
    trimmedQuery === settledQuery.trim()
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

  const choose = (href: string, state?: PodCommandNavigationState, recordQueryText?: string) => {
    if (recordQueryText) recordSearch(recordQueryText, pageResults.length)
    return onSelectTarget(href, state)
  }

  const { groups, entries, firstPageEntry } = useMemo(() => {
    const rawNav: Array<Omit<CommandNavigationEntry, 'kind' | 'url'>> = []
    if (agents.data?.personalAssistantAvailable) {
      const text = t('pod.chat.new_conversation')
      rawNav.push({
        value: 'new-chat',
        label: text,
        keywords: [text],
        href: '/',
        state: { focusComposer: true },
        icon: AddRegular
      })
    }
    rawNav.push({
      value: 'scope:search',
      label: t('pod.content.search_pages'),
      keywords: [t('pod.content.search_pages')],
      href: '/content/search',
      icon: SearchRegular
    })
    for (const scope of ['space', 'private', 'shared', 'recent', 'favorites', 'trash'] as const) {
      if (scope === 'private' && pages.data?.can_create_private === false) continue
      rawNav.push({
        value: `scope:${scope}`,
        label: scopeLabels[scope],
        keywords: [scopeLabels[scope]],
        href: `/content/${scope}`,
        icon: scopeIcons[scope]
      })
    }
    rawNav.push(
      {
        value: 'nav:meta-agents',
        label: t('pod.meta.agents'),
        keywords: [t('pod.meta.agents'), t('pod.meta.colleagues'), 'agents', 'ai'],
        href: '/meta/agents',
        icon: BotRegular
      },
      {
        value: 'nav:meta-skills',
        label: t('pod.meta.skills'),
        keywords: [t('pod.meta.skills'), 'skills'],
        href: '/meta/skills',
        icon: PuzzlePieceRegular
      },
      {
        value: 'nav:meta-brain',
        label: t('pod.meta.brain'),
        keywords: [t('pod.meta.brain'), t('pod.meta.graph'), 'brain'],
        href: '/meta/brain',
        icon: BrainRegular
      },
      {
        value: 'nav:meta-brain-mine',
        label: t('pod.meta.my_memories'),
        keywords: [t('pod.meta.my_memories'), t('pod.meta.brain'), 'memories', 'context'],
        href: '/meta/brain?lens=mine',
        icon: BrainRegular
      },
      {
        value: 'nav:connectors',
        label: t('pod.connectors.title'),
        keywords: [t('pod.connectors.title'), 'connectors', 'oauth', 'mcp'],
        href: '/connectors',
        icon: PlugConnectedRegular
      },
      {
        value: 'nav:account-settings',
        label: t('pod.account.title'),
        keywords: [t('pod.account.title')],
        href: '/me',
        icon: PersonRegular
      }
    )
    if (session.data?.canManagePod) {
      rawNav.push({
        value: 'nav:pod-settings',
        label: t('pod.settings.title'),
        keywords: [t('pod.settings.title')],
        href: '/settings',
        icon: SettingsRegular
      })
    }

    const navEntries: CommandNavigationEntry[] = (
      trimmedQuery ? rawNav.filter(item => commandFilter(item.value, trimmedQuery, item.keywords) > 0) : rawNav
    ).map(item => ({
      ...item,
      kind: 'nav',
      url: resolvePodTarget(item.href).url
    }))

    const recentEntries: CommandRecentSearchEntry[] = !trimmedQuery
      ? (recentSearches.data?.queries ?? []).map(entry => ({
          kind: 'recent-search',
          value: `recent-search:${entry.id}`,
          keywords: [entry.query],
          entry
        }))
      : []

    const pageEntries: CommandPageEntry[] = pageResults.map(page => {
      const title = page.title || t('pod.content.untitled')
      const parentPath = pagePathAncestors(page, pagesMap)
        .map(ancestor => ancestor.title || t('pod.content.untitled'))
        .join(' / ')
      const match = matchesByPageID.get(page.id)
      const href = buildSearchResultHref(
        pageHref(page.id, page.title),
        trimmedQuery,
        match?.primary_target,
        match?.match_fields ?? ['title']
      )
      return {
        kind: 'page',
        value: `page:${page.id}`,
        keywords: [title, typeLabels[page.type]],
        page,
        parentPath,
        match,
        href,
        url: resolvePodTarget(href).url,
        recordQuery: trimmedQuery || undefined
      }
    })

    const colleagueEntries: CommandColleagueEntry[] = colleagueResults.map(agent => {
      const href = `/dm/${encodeURIComponent(agent.uid)}`
      return {
        kind: 'colleague',
        value: `colleague:${agent.uid}`,
        keywords: [agent.uid, agent.displayName, agent.role ?? ''],
        agent,
        href,
        url: resolvePodTarget(href).url
      }
    })

    const skillEntries: CommandSkillEntry[] = skillResults.map(skill => {
      const href = `/meta/skills/${encodeURIComponent(skill.slug)}`
      return {
        kind: 'skill',
        value: `skill:${skill.slug}`,
        keywords: [skill.name, skill.slug, skill.description],
        skill,
        href,
        url: resolvePodTarget(href).url
      }
    })

    const settledClean = settledQuery.trim()
    const chatEntries: CommandChatEntry[] = conversationResults.map(conversation => {
      const title = conversationLabel(conversation, t('pod.content.untitled'))
      const base =
        conversation.conversationKind === 'colleague_dm'
          ? `/dm/${encodeURIComponent(conversation.agents[0]!.uid)}`
          : `/conversations/${conversation.id}`
      const href =
        conversation.searchMatch && settledClean
          ? `${base}?${new URLSearchParams({ find: settledClean, seq: String(conversation.searchMatch.seq) })}`
          : base
      return {
        kind: 'chat',
        value: `chat:${conversation.id}`,
        keywords: [title],
        conversation,
        href,
        url: resolvePodTarget(href).url,
        state:
          conversation.searchMatch && settledClean
            ? { findMessage: { query: settledClean, seq: conversation.searchMatch.seq } }
            : undefined,
        recordQuery: trimmedQuery || undefined
      }
    })

    const exactNavMatch =
      Boolean(trimmedQuery) &&
      navEntries.some(item =>
        item.keywords.some(keyword => normalizeSearchQuery(keyword) === normalizeSearchQuery(trimmedQuery))
      )

    const orderedGroups: CommandEntryGroup[] = []
    const pushRecent = () => {
      if (recentEntries.length > 0) orderedGroups.push({ kind: 'recent-search', entries: recentEntries })
    }
    const pushPages = () => {
      if (pageEntries.length > 0) {
        orderedGroups.push({
          kind: 'page',
          heading: trimmedQuery ? t('pod.content.all_pages') : t('pod.command.recent_pages'),
          entries: pageEntries
        })
      }
    }
    const pushNav = () => {
      if (navEntries.length > 0) {
        orderedGroups.push({
          kind: 'nav',
          heading: t('pod.content.page_navigation'),
          entries: navEntries
        })
      }
    }
    const pushColleagues = () => {
      if (colleagueEntries.length > 0) {
        orderedGroups.push({
          kind: 'colleague',
          heading: t('pod.superagent.messages_colleagues'),
          entries: colleagueEntries
        })
      }
    }
    const pushSkills = () => {
      if (skillEntries.length > 0) {
        orderedGroups.push({
          kind: 'skill',
          heading: t('pod.meta.skills'),
          entries: skillEntries
        })
      }
    }
    const pushChats = () => {
      if (chatEntries.length > 0) {
        orderedGroups.push({
          kind: 'chat',
          heading: t('pod.sidebar.tabs.chat'),
          entries: chatEntries
        })
      }
    }

    if (!trimmedQuery) {
      pushRecent()
      pushPages()
      pushNav()
      pushChats()
    } else if (exactNavMatch) {
      pushNav()
      pushPages()
      pushColleagues()
      pushSkills()
      pushChats()
    } else {
      pushPages()
      pushColleagues()
      pushSkills()
      pushChats()
      pushNav()
    }

    const flatEntries = orderedGroups.flatMap<CommandEntry>(group => group.entries)
    return {
      groups: orderedGroups,
      entries: flatEntries,
      firstPageEntry: pageEntries[0]
    }
  }, [
    agents.data?.personalAssistantAvailable,
    colleagueResults,
    conversationResults,
    matchesByPageID,
    pageHref,
    pageResults,
    pages.data?.can_create_private,
    pagesMap,
    recentSearches.data?.queries,
    session.data?.canManagePod,
    settledQuery,
    skillResults,
    t,
    trimmedQuery
  ])

  const effectiveActiveEntry = useMemo(
    () => (activeValue ? entries.find(entry => entry.value === activeValue) : undefined) ?? entries[0],
    [activeValue, entries]
  )
  const effectiveActiveValue = effectiveActiveEntry?.value ?? ''

  const openFullSearchHref = useMemo(() => {
    const params = new URLSearchParams()
    if (trimmedQuery) params.set('q', trimmedQuery)
    if (titleOnly) params.set('title_only', 'true')
    if (sort !== 'best') params.set('sort', sort)
    if (scopePageID) params.set('ancestor_id', scopePageID)
    const qs = params.toString()
    return `/content/search${qs ? `?${qs}` : ''}`
  }, [scopePageID, sort, titleOnly, trimmedQuery])

  const label = t('pod.command.open')
  const isSearching = trimmedQuery !== settledQuery.trim() || pages.isFetching || conversations.isFetching
  const apple = isApplePlatform()

  return (
    <>
      <ErrorBoundary variant="panel" className="m-3" resetKeys={[open]}>
        <Command
          label={label}
          loop
          vimBindings={false}
          shouldFilter={false}
          value={effectiveActiveValue}
          onValueChange={onActiveValueChange}
          onKeyDownCapture={event => {
            if (isImeComposingKey(event)) {
              if (event.key === 'Enter') event.stopPropagation()
              return
            }
            if (isCommandInteractiveTarget(event.target)) return
            if (
              event.target === inputRef.current &&
              (apple ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey) &&
              !event.altKey &&
              !event.shiftKey &&
              !event.repeat &&
              /^[1-5]$/.test(event.key)
            ) {
              const value = shortcutCommands[Number(event.key) - 1]
              const entry = entries.find(item => item.value === value)
              if (entry?.kind === 'nav') {
                event.preventDefault()
                event.stopPropagation()
                void choose(entry.href, entry.state)
              }
              return
            }
            if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
              const url = effectiveActiveEntry && 'url' in effectiveActiveEntry ? effectiveActiveEntry.url : undefined
              if (url && onOpenNewWindow) {
                event.preventDefault()
                event.stopPropagation()
                if (trimmedQuery) recordSearch(trimmedQuery, pageResults.length)
                onOpenNewWindow(url)
              }
            }
          }}>
          <CommandInput
            ref={inputRef}
            aria-label={label}
            aria-keyshortcuts="Alt+ArrowUp Alt+ArrowDown"
            placeholder={t('pod.command.placeholder')}
            value={query}
            onValueChange={next => {
              onQueryChange(next)
              onActiveValueChange('')
            }}
            autoCorrect="off"
            autoCapitalize="off"
            spellCheck={false}
            autoFocus
          />

          <div className="flex flex-wrap items-center justify-between gap-1.5 border-b border-divider-overlay px-1.5 py-1">
            <div className="flex flex-wrap items-center gap-1">
              <Button
                type="button"
                size="sm"
                variant={titleOnly ? 'outline' : 'ghost'}
                aria-pressed={titleOnly}
                className="px-2 text-xs"
                onClick={() => onTitleOnlyChange(prev => !prev)}>
                {t('pod.command.title_only')}
              </Button>
              {currentPageID && (
                <Button
                  type="button"
                  size="sm"
                  variant={inCurrentPage ? 'outline' : 'ghost'}
                  aria-pressed={inCurrentPage}
                  className="max-w-48 truncate px-2 text-xs"
                  onClick={() => onInCurrentPageChange(prev => !prev)}>
                  {currentPageTitle
                    ? t('pod.command.in_page_chip', { title: currentPageTitle })
                    : t('pod.command.search_in_current_page')}
                </Button>
              )}
            </div>
            <DropdownMenu>
              <DropdownMenuTrigger
                render={
                  <Button
                    type="button"
                    size="sm"
                    variant="ghost"
                    aria-label={t('pod.command.sort_label')}
                    className="gap-1 px-2 text-xs"
                  />
                }>
                <span>
                  {sort === 'updated_desc'
                    ? t('pod.command.sort_updated_desc')
                    : sort === 'updated_asc'
                      ? t('pod.command.sort_updated_asc')
                      : sort === 'created_desc'
                        ? t('pod.command.sort_created_desc')
                        : sort === 'created_asc'
                          ? t('pod.command.sort_created_asc')
                          : t('pod.command.sort_best')}
                </span>
                <ChevronDownRegular aria-hidden className="size-3.5 text-fg-tertiary" />
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                <DropdownMenuRadioGroup value={sort} onValueChange={next => onSortChange(next as PageSearchSort)}>
                  <DropdownMenuRadioItem value="best">{t('pod.command.sort_best')}</DropdownMenuRadioItem>
                  <DropdownMenuRadioItem value="updated_desc">
                    {t('pod.command.sort_updated_desc')}
                  </DropdownMenuRadioItem>
                  <DropdownMenuRadioItem value="updated_asc">{t('pod.command.sort_updated_asc')}</DropdownMenuRadioItem>
                  <DropdownMenuRadioItem value="created_desc">
                    {t('pod.command.sort_created_desc')}
                  </DropdownMenuRadioItem>
                  <DropdownMenuRadioItem value="created_asc">{t('pod.command.sort_created_asc')}</DropdownMenuRadioItem>
                </DropdownMenuRadioGroup>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>

          <div className="grid min-h-0 md:grid-cols-[minmax(0,1fr)_minmax(0,300px)]">
            <CommandList label={label} aria-busy={isSearching} className="min-w-0">
              <CommandHighlight />
              <CommandEmpty>{t(isSearching ? 'pod.content.loading' : 'pod.content.no_matches')}</CommandEmpty>

              {groups.map(group => {
                switch (group.kind) {
                  case 'recent-search':
                    return (
                      <CommandGroup
                        key="recent-search"
                        heading={
                          // The group title is a flex row, so its content stretches to put the action at the end.
                          <span className="flex flex-1 items-center justify-between gap-2">
                            <span>{t('pod.command.recent_searches')}</span>
                            <Button
                              type="button"
                              variant="ghost"
                              size="xs"
                              onClick={event => {
                                event.preventDefault()
                                event.stopPropagation()
                                clearRecents.mutate()
                              }}>
                              {t('pod.command.clear_recent_searches')}
                            </Button>
                          </span>
                        }>
                        {group.entries.map(({ value, keywords, entry }) => (
                          <CommandItem
                            key={entry.id}
                            value={value}
                            keywords={keywords}
                            onSelect={() => {
                              onQueryChange(entry.query)
                              onActiveValueChange('')
                            }}>
                            <HistoryRegular aria-hidden className="text-fg-tertiary" />
                            <span className="min-w-0 flex-1 truncate">{entry.query}</span>
                            <Button
                              type="button"
                              variant="ghost"
                              size="icon-xs"
                              aria-label={t('pod.command.remove_recent_search', { query: entry.query })}
                              onClick={event => {
                                event.preventDefault()
                                event.stopPropagation()
                                deleteRecent.mutate(entry.id)
                              }}>
                              {/* The row gives 16px to every icon without a size class, so this icon names the
                                    button's 14px size. */}
                              <DismissRegular aria-hidden className="size-3.5" />
                            </Button>
                          </CommandItem>
                        ))}
                      </CommandGroup>
                    )

                  case 'page':
                    return (
                      <CommandGroup key="page" heading={group.heading}>
                        {group.entries.map(item => {
                          const targetBadge = formatSearchTargetBadge(item.match?.primary_target, t)
                          return (
                            <CommandItem
                              key={item.page.id}
                              value={item.value}
                              keywords={item.keywords}
                              onSelect={() => void choose(item.href, undefined, item.recordQuery)}>
                              <PageIcon page={item.page} />
                              <span className="min-w-0 flex-1 space-y-0.5">
                                <span className="flex items-center gap-1.5">
                                  <HighlightedBdiLabel
                                    className="min-w-0 flex-1"
                                    value={item.page.title}
                                    fallback={t('pod.content.untitled')}
                                    query={trimmedQuery}
                                  />
                                  {targetBadge && (
                                    <span className="max-w-36 shrink-0 truncate rounded-mini bg-muted px-1.5 py-0.5 text-[11px] leading-4 text-fg-secondary">
                                      {targetBadge}
                                    </span>
                                  )}
                                </span>
                                {item.parentPath && (
                                  <span className="block truncate text-xs text-fg-tertiary">{item.parentPath}</span>
                                )}
                                {trimmedQuery && item.match?.snippet && item.match.snippet.segments.length > 0 && (
                                  <SearchSnippet snippet={item.match.snippet} />
                                )}
                              </span>
                              <span className="shrink-0 text-xs text-fg-tertiary">{typeLabels[item.page.type]}</span>
                            </CommandItem>
                          )
                        })}
                      </CommandGroup>
                    )

                  case 'nav':
                    return (
                      <CommandGroup key="nav" heading={group.heading}>
                        {group.entries.map(item => {
                          const Icon = item.icon
                          const shortcut = shortcutCommands.indexOf(item.value) + 1
                          return (
                            <CommandItem
                              key={item.value}
                              value={item.value}
                              keywords={item.keywords}
                              aria-keyshortcuts={shortcut ? `${apple ? 'Meta' : 'Control'}+${shortcut}` : undefined}
                              onSelect={() => void choose(item.href, item.state)}>
                              <Icon aria-hidden />
                              {item.label}
                              {shortcut > 0 && (
                                <CommandShortcut aria-hidden className="hidden sm:inline-flex">
                                  <Kbd>
                                    {apple ? '⌘' : 'Ctrl+'}
                                    {shortcut}
                                  </Kbd>
                                </CommandShortcut>
                              )}
                            </CommandItem>
                          )
                        })}
                      </CommandGroup>
                    )

                  case 'colleague':
                    return (
                      <CommandGroup key="colleague" heading={group.heading}>
                        {group.entries.map(item => (
                          <CommandItem
                            key={item.agent.uid}
                            value={item.value}
                            keywords={item.keywords}
                            onSelect={() => void choose(item.href)}>
                            <span className="pod-conversation-glyph">
                              <ChatAvatar name={item.agent.displayName} src={item.agent.avatarURL} agent />
                            </span>
                            <span className="min-w-0 flex-1">
                              <span className="block truncate">
                                <AgentName agent={item.agent} />
                              </span>
                              {item.agent.role && (
                                <span className="block truncate text-xs text-fg-tertiary">{item.agent.role}</span>
                              )}
                            </span>
                          </CommandItem>
                        ))}
                      </CommandGroup>
                    )

                  case 'skill':
                    return (
                      <CommandGroup key="skill" heading={group.heading}>
                        {group.entries.map(item => (
                          <CommandItem
                            key={item.skill.id}
                            value={item.value}
                            keywords={item.keywords}
                            onSelect={() => void choose(item.href)}>
                            <PuzzlePieceRegular aria-hidden className="text-fg-tertiary" />
                            <span className="min-w-0 flex-1">
                              <span className="flex items-center gap-1.5">
                                <span className="truncate font-medium">
                                  <HighlightedText text={item.skill.name} query={trimmedQuery} />
                                </span>
                                <code className="shrink-0 rounded-mini bg-muted px-1.5 py-0.5 font-mono text-[11px] text-fg-secondary">
                                  /{item.skill.slug}
                                </code>
                              </span>
                              {item.skill.description && (
                                <span className="block truncate text-xs text-fg-tertiary">
                                  <HighlightedText text={item.skill.description} query={trimmedQuery} />
                                </span>
                              )}
                            </span>
                          </CommandItem>
                        ))}
                      </CommandGroup>
                    )

                  case 'chat':
                    return (
                      <CommandGroup key="chat" heading={group.heading}>
                        {group.entries.map(item => (
                          <CommandItem
                            key={item.conversation.id}
                            value={item.value}
                            keywords={item.keywords}
                            onSelect={() => void choose(item.href, item.state, item.recordQuery)}>
                            <ConversationGlyph room={item.conversation} />
                            <span className="min-w-0 flex-1">
                              <span className="block truncate">
                                <ConversationTitle room={item.conversation} />
                              </span>
                              {item.conversation.searchMatch && (
                                <span className="block truncate text-xs text-fg-secondary">
                                  <HighlightedText text={item.conversation.searchMatch.excerpt} query={trimmedQuery} />
                                </span>
                              )}
                            </span>
                          </CommandItem>
                        ))}
                      </CommandGroup>
                    )
                }
              })}
            </CommandList>

            <CommandMenuPreview
              open={open}
              activeEntry={effectiveActiveEntry}
              fallbackPageEntry={firstPageEntry}
              pagesMap={pagesMap}
              trimmedQuery={trimmedQuery}
              isSearching={isSearching}
              onChoose={choose}
            />
          </div>

          <div className="flex flex-wrap items-center justify-between gap-2 border-t border-divider-overlay px-2 pt-1.5 text-[11px] text-fg-tertiary">
            <div className="flex items-center gap-3">
              <span>{t('pod.command.hint_navigate')}</span>
              <span className="hidden md:inline">
                {t('pod.command.hint_group', { modifier: apple ? '⌥' : 'Alt+' })}
              </span>
              <span>{t('pod.command.hint_open')}</span>
              <span className="hidden sm:inline">{t('pod.command.hint_new_tab')}</span>
            </div>
            {trimmedQuery && (
              <Button
                type="button"
                variant="ghost"
                size="xs"
                onClick={() => void choose(openFullSearchHref, undefined, trimmedQuery)}>
                {t('pod.command.view_all_results')}
                <ArrowUpRightRegular aria-hidden data-icon="inline-end" />
              </Button>
            )}
          </div>
        </Command>
      </ErrorBoundary>
      {(pages.isPending || conversations.isPending) && <InlineLoading className="px-3 text-xs" />}
      <ContentError
        error={pages.error || conversations.error}
        retry={() => {
          void pages.refetch()
          void conversations.refetch()
        }}
      />
    </>
  )
}
