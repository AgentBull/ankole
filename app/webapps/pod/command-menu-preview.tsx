import { Button } from '@ankole/uikit'
import { useMemo } from 'react'
import { InlineLoading } from './content-primitives'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { PuzzlePieceRegular } from '@ankole/uikit/icons'
import type { IconComponent } from '@ankole/uikit/icons'
import { useDebouncedValue } from '../common/use-debounced-value'
import type { PodAgent } from './api'
import { pageQuery, type Page, type PageSearchMatch, type RecentSearchEntry } from './content-api'
import type { MetaSkill } from './meta-api'
import { ChatAvatar } from './chat/chat-avatar'
import { AgentName, ConversationGlyph, ConversationTitle, type RoomRow } from './chat/conversation-row'
import { PageIcon } from './page-icon'
import { HighlightedBdiLabel, HighlightedText, SearchSnippet } from './search-highlight'
import { buildSearchResultHref, extractXmlPreview, formatSearchTargetBadge } from './search-targets'
import { pagePathAncestors } from './state/page-location'
import { usePageHref } from './use-page-metadata'
import type { PodCommandNavigationState } from './command-menu'

export type CommandRecentSearchEntry = {
  kind: 'recent-search'
  value: string
  keywords: string[]
  entry: RecentSearchEntry
}

export type CommandPageEntry = {
  kind: 'page'
  value: string
  keywords: string[]
  page: Page
  parentPath: string
  match?: PageSearchMatch
  href: string
  url: string
  recordQuery?: string
}

export type CommandNavigationEntry = {
  kind: 'nav'
  value: string
  label: string
  keywords: string[]
  href: string
  url: string
  state?: PodCommandNavigationState
  icon: IconComponent
}

export type CommandColleagueEntry = {
  kind: 'colleague'
  value: string
  keywords: string[]
  agent: PodAgent
  href: string
  url: string
}

export type CommandChatEntry = {
  kind: 'chat'
  value: string
  keywords: string[]
  conversation: RoomRow
  href: string
  url: string
  state?: PodCommandNavigationState
  recordQuery?: string
}

export type CommandSkillEntry = {
  kind: 'skill'
  value: string
  keywords: string[]
  skill: MetaSkill
  href: string
  url: string
}

export type CommandEntry =
  | CommandRecentSearchEntry
  | CommandPageEntry
  | CommandNavigationEntry
  | CommandColleagueEntry
  | CommandChatEntry
  | CommandSkillEntry

export function CommandMenuPreview({
  open,
  activeEntry,
  fallbackPageEntry,
  pagesMap,
  trimmedQuery,
  isSearching,
  onChoose
}: {
  open: boolean
  activeEntry?: CommandEntry
  fallbackPageEntry?: CommandPageEntry
  pagesMap: ReadonlyMap<string, Page>
  trimmedQuery: string
  isSearching: boolean
  onChoose: (href: string, state?: PodCommandNavigationState, recordQueryText?: string) => unknown
}) {
  const { t } = useTranslation()
  const pageHref = usePageHref()

  const targetPageEntry =
    activeEntry?.kind === 'page'
      ? activeEntry
      : activeEntry?.kind === 'recent-search' || !activeEntry
        ? fallbackPageEntry
        : undefined

  const previewPageID = targetPageEntry?.page.id
  const debouncedPreviewID = useDebouncedValue(previewPageID ?? '', 120)
  const preview = useQuery({
    ...pageQuery(debouncedPreviewID),
    enabled: open && Boolean(debouncedPreviewID)
  })

  const previewPage =
    targetPageEntry?.page ??
    (previewPageID && preview.data?.page.id === previewPageID ? (preview.data.page as Page) : undefined)
  const previewMatch = targetPageEntry?.match

  const xmlPreview = useMemo(
    () =>
      previewPageID && preview.data?.page.id === previewPageID
        ? extractXmlPreview(preview.data?.content?.content, trimmedQuery)
        : { headings: [], blocks: [], excerptSkippedBefore: false },
    [preview.data?.content?.content, preview.data?.page.id, previewPageID, trimmedQuery]
  )

  return (
    <aside
      data-testid="command-preview-pane"
      className="pod-command-preview hidden min-w-0 flex-col gap-3 overflow-y-auto border-l border-divider-overlay p-3 md:flex">
      {activeEntry?.kind === 'chat' ? (
        <div className="space-y-3">
          <div className="flex items-center gap-2.5">
            <ConversationGlyph room={activeEntry.conversation} size="md" />
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-medium text-foreground">
                <ConversationTitle room={activeEntry.conversation} />
              </p>
              {activeEntry.conversation.agents.length > 0 && (
                <p className="truncate text-xs text-fg-tertiary">
                  {activeEntry.conversation.agents.map(agent => agent.displayName).join(', ')}
                </p>
              )}
            </div>
          </div>
          {activeEntry.conversation.searchMatch ? (
            <p className="line-clamp-8 whitespace-pre-wrap text-xs leading-5 text-fg-secondary">
              <HighlightedText text={activeEntry.conversation.searchMatch.excerpt} query={trimmedQuery} />
            </p>
          ) : (
            <p className="text-xs text-fg-tertiary">{t('pod.sidebar.tabs.chat')}</p>
          )}
        </div>
      ) : activeEntry?.kind === 'colleague' ? (
        <div className="space-y-2">
          <div className="flex items-center gap-2.5">
            <span className="pod-conversation-glyph" data-size="md">
              <ChatAvatar name={activeEntry.agent.displayName} src={activeEntry.agent.avatarURL} agent />
            </span>
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-medium text-foreground">
                <AgentName agent={activeEntry.agent} />
              </p>
              <p className="truncate text-xs text-fg-tertiary">@{activeEntry.agent.uid}</p>
            </div>
          </div>
          {activeEntry.agent.role && <p className="text-xs leading-5 text-fg-secondary">{activeEntry.agent.role}</p>}
        </div>
      ) : activeEntry?.kind === 'skill' ? (
        <div className="space-y-2">
          <div className="flex items-center gap-2">
            <PuzzlePieceRegular aria-hidden className="size-4 shrink-0 text-fg-tertiary" />
            <p className="min-w-0 flex-1 truncate text-sm font-medium text-foreground">
              <HighlightedText text={activeEntry.skill.name} query={trimmedQuery} />
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-1.5 text-xs text-fg-tertiary">
            <code className="rounded-mini bg-muted px-1.5 py-0.5 font-mono text-[11px] text-fg-secondary">
              /{activeEntry.skill.slug}
            </code>
            <span>·</span>
            <span>{t(`pod.meta.source_${activeEntry.skill.source_kind}`)}</span>
          </div>
          {activeEntry.skill.description && (
            <p className="text-xs leading-5 text-fg-secondary">
              <HighlightedText text={activeEntry.skill.description} query={trimmedQuery} />
            </p>
          )}
        </div>
      ) : activeEntry?.kind === 'nav' ? (
        <div className="space-y-1.5">
          <div className="flex items-center gap-2 text-sm font-medium text-foreground">
            <activeEntry.icon aria-hidden className="size-4 shrink-0 text-fg-tertiary" />
            <span className="truncate">{activeEntry.label}</span>
          </div>
          <p className="text-xs text-fg-tertiary">{t('pod.content.page_navigation')}</p>
        </div>
      ) : previewPage ? (
        <>
          <div className="space-y-1">
            <div className="flex items-center gap-2">
              <PageIcon page={previewPage} />
              <HighlightedBdiLabel
                className="min-w-0 flex-1 text-sm font-medium text-foreground"
                value={previewPage.title}
                fallback={t('pod.content.untitled')}
                query={trimmedQuery}
              />
            </div>
            {(() => {
              const crumb =
                targetPageEntry?.parentPath ??
                pagePathAncestors(previewPage, pagesMap)
                  .map(ancestor => ancestor.title || t('pod.content.untitled'))
                  .join(' / ')
              return crumb ? <p className="truncate text-xs text-fg-tertiary">{crumb}</p> : null
            })()}
          </div>

          {xmlPreview.headings.length > 0 && (
            <div>
              {/* The title starts where the first level of sections does, 8px in. */}
              <p className="menu-group-label px-2">{t('pod.command.sections')}</p>
              <div className="flex flex-col gap-0.5">
                {xmlPreview.headings.slice(0, 10).map((sec, idx) => (
                  <Button
                    key={`${sec.level}-${sec.text}-${idx}`}
                    type="button"
                    variant="ghost"
                    size="xs"
                    className="w-full justify-start font-normal"
                    style={{ paddingInlineStart: `${Math.min(sec.level - 1, 3) * 8 + 8}px` }}
                    onClick={() =>
                      void onChoose(
                        buildSearchResultHref(pageHref(previewPage.id, previewPage.title), trimmedQuery, {
                          kind: 'doc_section',
                          heading: sec.text,
                          level: sec.level
                        }),
                        undefined,
                        trimmedQuery
                      )
                    }>
                    <span className="min-w-0 truncate">
                      § <HighlightedText text={sec.text} query={trimmedQuery} />
                    </span>
                  </Button>
                ))}
              </div>
            </div>
          )}

          <div className="space-y-2 text-xs leading-5 text-fg-secondary">
            {xmlPreview.blocks.length > 0 ? (
              <>
                {xmlPreview.excerptSkippedBefore && (
                  <p aria-hidden className="text-fg-tertiary">
                    …
                  </p>
                )}
                {xmlPreview.blocks.slice(0, 12).map((block, idx) => (
                  <p
                    key={idx}
                    className={
                      block.kind === 'heading'
                        ? 'font-medium text-foreground'
                        : block.kind === 'code'
                          ? 'overflow-x-auto rounded-mini bg-muted px-2 py-1 font-mono text-[11px]'
                          : block.kind === 'quote'
                            ? 'border-l-2 border-border pl-2 italic'
                            : 'line-clamp-3'
                    }>
                    <HighlightedText text={block.text} query={trimmedQuery} />
                  </p>
                ))}
              </>
            ) : preview.data?.page.id === previewPage.id && preview.data?.content?.plain_text?.trim() ? (
              <p className="line-clamp-10 whitespace-pre-wrap">
                <HighlightedText text={preview.data.content.plain_text.trim().slice(0, 600)} query={trimmedQuery} />
              </p>
            ) : previewMatch?.snippet && previewMatch.snippet.segments.length > 0 ? (
              <div className="space-y-1.5">
                {(() => {
                  const badge = formatSearchTargetBadge(previewMatch.primary_target, t)
                  return badge ? (
                    <span className="inline-block rounded-mini bg-muted px-1.5 py-0.5 text-[11px] text-fg-secondary">
                      {badge}
                    </span>
                  ) : null
                })()}
                <SearchSnippet snippet={previewMatch.snippet} />
              </div>
            ) : preview.isPending ? (
              <InlineLoading label={t('pod.command.preview_loading')} />
            ) : (
              <p className="text-fg-tertiary">{t('pod.command.preview_empty')}</p>
            )}
          </div>
        </>
      ) : (
        <p className="text-xs text-fg-tertiary">
          {t(isSearching ? 'pod.command.preview_loading' : 'pod.content.no_matches')}
        </p>
      )}
    </aside>
  )
}
