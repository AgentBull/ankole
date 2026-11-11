import { SidebarMenu, SidebarMenuButton, SidebarMenuItem } from '@ankole/uikit'
import { RiKanbanView } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { Link, useLocation } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import { podLocation } from '../common/browser-context'
import { ChatRowStatus } from './chat/conversation-row'
import { ContentError, ContentSkeleton } from './content-primitives'
import { workItemsQuery, type WorkItem, type WorkStatus } from './work-api'
import './chat.css'

// The viewer's inbox comes first: an answer the Agent needs, then results to review. Accepted work stays on the board.
const sections: WorkStatus[] = ['waiting', 'review', 'working', 'todo']

// The marks a conversation row uses in Chat, so the same state looks the same in both tabs.
const marks: Partial<Record<WorkStatus, 'waiting_choice' | 'running_background'>> = {
  waiting: 'waiting_choice',
  working: 'running_background'
}

/** The Work tab of the sidebar: a link to the board, then the open work items by where they stand. */
export function WorkNavigation({ onNavigate }: { onNavigate(): void }) {
  const { t } = useTranslation()
  const workPath = podLocation('/work').pathname
  const location = useLocation({ select: location => ({ pathname: location.pathname, search: location.searchStr }) })
  const onWork = location.pathname === workPath
  const selected = onWork ? new URLSearchParams(location.search).get('issue') : null
  const items = useQuery(workItemsQuery)
  const row = (item: WorkItem) => {
    const mark = marks[item.status as WorkStatus]
    return (
      <SidebarMenuItem key={item.id} className="pod-chat-row" data-lines={1}>
        <SidebarMenuButton
          render={<Link to={workPath} search={{ issue: item.id }} />}
          isActive={selected === item.id}
          onClick={onNavigate}
          title={item.title}>
          <span className="pod-chat-row-line" dir="auto">
            <span className="pod-chat-row-title">{item.title || t('pod.content.untitled')}</span>
            {mark && (
              <span className="pod-chat-row-trailing">
                <ChatRowStatus status={mark} />
              </span>
            )}
          </span>
        </SidebarMenuButton>
      </SidebarMenuItem>
    )
  }
  return (
    <nav aria-label={t('pod.sidebar.tabs.work')} className="pod-navigation">
      <ul className="pod-nav-places">
        <li>
          <Link
            className="nav-row pod-nav-link"
            to={workPath}
            activeOptions={{ exact: true, includeSearch: true }}
            aria-current={onWork && !selected ? 'page' : undefined}
            onClick={onNavigate}>
            <RiKanbanView aria-hidden />
            <span className="truncate">{t('pod.work.board')}</span>
          </Link>
        </li>
      </ul>
      {items.isPending ? (
        <ContentSkeleton variant="list" rows={3} className="pod-tree-empty" />
      ) : items.error && !items.data ? (
        <ContentError error={items.error} retry={() => void items.refetch()} />
      ) : (
        sections.map(status => {
          const rows = (items.data ?? []).filter(item => item.status === status)
          if (!rows.length) return null
          const label = t(`pod.work.status.${status}`)
          return (
            <section key={status} aria-label={label} className="pod-nav-section">
              <div className="pod-nav-section-heading">
                <span className="min-w-0 flex-1 truncate">{label}</span>
                <span className="pod-chat-section-count">{rows.length}</span>
              </div>
              <SidebarMenu>{rows.map(row)}</SidebarMenu>
            </section>
          )
        })
      )}
    </nav>
  )
}
