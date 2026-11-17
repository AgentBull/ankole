import {
  Badge,
  BoardPresence,
  Button,
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
  InputGroup,
  InputGroupAddon,
  InputGroupButton,
  InputGroupInput,
  Tabs,
  TabsList,
  TabsTrigger
} from '@ankole/uikit'
import { AddRegular, DismissRegular, FilterRegular, SearchRegular, WarningRegular } from '@ankole/uikit/icons'
import type { RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { ChatAvatar } from './chat/chat-avatar'
import type { JobBoardItem, JobCandidateAgent } from './jobs-api'

export const JOB_KINDS: ReadonlyArray<JobBoardItem['kind']> = [
  'background_agent_job',
  'workflow',
  'cron',
  'automation_job',
  'checkback'
]

export interface WorkingAgentSummary {
  uid: string
  name: string
  avatarURL?: string | null
}

export function JobsBoardHeader({
  agents,
  workingAgents,
  attentionCount,
  showToolbar,
  viewMode,
  agentFilter,
  filteredAgentName,
  kindFilter,
  inputQuery,
  activeFilterCount,
  createButtonRef,
  onNewJob,
  onViewModeChange,
  onAgentFilterChange,
  onKindFilterChange,
  onQueryChange,
  onClearFilters
}: {
  agents: JobCandidateAgent[]
  workingAgents: WorkingAgentSummary[]
  attentionCount: number
  showToolbar: boolean
  viewMode: 'status' | 'agent'
  agentFilter?: string
  filteredAgentName?: string
  kindFilter?: JobBoardItem['kind']
  inputQuery: string
  activeFilterCount: number
  createButtonRef: RefObject<HTMLButtonElement | null>
  onNewJob: () => void
  onViewModeChange: (next: 'status' | 'agent') => void
  onAgentFilterChange: (agentUID: string | undefined) => void
  onKindFilterChange: (kind: JobBoardItem['kind'] | undefined) => void
  onQueryChange: (value: string) => void
  onClearFilters: () => void
}) {
  const { t } = useTranslation()

  return (
    <header className="mb-4 flex flex-col gap-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex min-w-0 flex-wrap items-center gap-2.5">
          <h1 className="title-page text-fg-primary">{t('pod.jobs.title')}</h1>
          {workingAgents.length > 0 && (
            <BoardPresence
              avatars={workingAgents.slice(0, 4).map(agent => (
                <ChatAvatar key={agent.uid} name={agent.name} src={agent.avatarURL} agent size="xs" />
              ))}>
              {workingAgents.length === 1
                ? t('pod.jobs.working_single', { name: workingAgents[0]!.name })
                : t('pod.jobs.working_count', { count: workingAgents.length })}
            </BoardPresence>
          )}
          {attentionCount > 0 && (
            <span className="inline-flex h-7 shrink-0 items-center gap-1.5 rounded-full border border-(--board-warning-chip-edge) bg-(--board-warning-chip) px-2.5 text-xs leading-4 font-medium text-fg-primary">
              <WarningRegular aria-hidden className="size-3.5 text-(--board-warning-icon)" />
              {t('pod.jobs.summary_attention', { count: attentionCount })}
            </span>
          )}
        </div>

        {agents.length > 0 && (
          <Button ref={createButtonRef} type="button" size="sm" onClick={onNewJob}>
            <AddRegular aria-hidden />
            {t('pod.jobs.new_job')}
          </Button>
        )}
      </div>

      {showToolbar && (
        <div className="flex flex-wrap items-center justify-between gap-2.5">
          <div className="flex flex-wrap items-center gap-2">
            <Tabs value={viewMode} onValueChange={value => onViewModeChange(value === 'agent' ? 'agent' : 'status')}>
              <TabsList variant="object" aria-label={t('pod.jobs.view_label')}>
                <TabsTrigger value="status">{t('pod.jobs.view_status')}</TabsTrigger>
                <TabsTrigger value="agent">{t('pod.jobs.view_agent')}</TabsTrigger>
              </TabsList>
            </Tabs>

            {agentFilter && filteredAgentName && (
              <Badge variant="secondary" className="h-7 gap-1 rounded-control px-2 text-xs font-normal">
                <span className="text-fg-tertiary">{t('pod.jobs.field_agent')}:</span>
                <span className="max-w-32 truncate font-medium text-fg-primary">{filteredAgentName}</span>
                <button
                  type="button"
                  aria-label={t('pod.jobs.clear_filters')}
                  onClick={() => onAgentFilterChange(undefined)}
                  className="ms-0.5 inline-flex size-4 cursor-pointer items-center justify-center rounded-micro text-fg-tertiary hover:bg-layer-hover hover:text-fg-primary">
                  <DismissRegular aria-hidden className="size-3" />
                </button>
              </Badge>
            )}

            {kindFilter && (
              <Badge variant="secondary" className="h-7 gap-1 rounded-control px-2 text-xs font-normal">
                <span className="text-fg-tertiary">{t('pod.jobs.filter_kind')}:</span>
                <span className="max-w-32 truncate font-medium text-fg-primary">
                  {t(`pod.jobs.kinds.${kindFilter}`)}
                </span>
                <button
                  type="button"
                  aria-label={t('pod.jobs.clear_filters')}
                  onClick={() => onKindFilterChange(undefined)}
                  className="ms-0.5 inline-flex size-4 cursor-pointer items-center justify-center rounded-micro text-fg-tertiary hover:bg-layer-hover hover:text-fg-primary">
                  <DismissRegular aria-hidden className="size-3" />
                </button>
              </Badge>
            )}
          </div>

          <div className="flex flex-wrap items-center gap-2">
            <InputGroup className="h-7 w-44 px-2.5 text-xs sm:w-56">
              <InputGroupAddon align="inline-start" className="py-0">
                <SearchRegular aria-hidden className="size-3.5 text-fg-tertiary" />
              </InputGroupAddon>
              <InputGroupInput
                type="search"
                value={inputQuery}
                onChange={event => onQueryChange(event.target.value)}
                placeholder={t('pod.jobs.search_placeholder')}
                aria-label={t('pod.jobs.search_placeholder')}
                className="h-7 py-0 text-xs"
              />
              {inputQuery && (
                <InputGroupAddon align="inline-end" className="py-0">
                  <InputGroupButton
                    size="icon-xs"
                    aria-label={t('pod.jobs.clear_search')}
                    onClick={() => onQueryChange('')}>
                    <DismissRegular aria-hidden className="size-3" />
                  </InputGroupButton>
                </InputGroupAddon>
              )}
            </InputGroup>

            <DropdownMenu>
              <DropdownMenuTrigger
                render={
                  <Button type="button" variant="outline" size="sm">
                    <FilterRegular aria-hidden />
                    {t('pod.jobs.filter')}
                    {activeFilterCount > 0 && (
                      <Badge variant="info" size="sm">
                        {activeFilterCount}
                      </Badge>
                    )}
                  </Button>
                }
              />
              <DropdownMenuContent align="end" className="min-w-52">
                {agents.length > 0 && (
                  <>
                    <DropdownMenuGroup>
                      <DropdownMenuLabel>{t('pod.jobs.field_agent')}</DropdownMenuLabel>
                      {agents.map(agent => (
                        <DropdownMenuCheckboxItem
                          key={agent.uid}
                          checked={agentFilter === agent.uid}
                          onCheckedChange={checked => onAgentFilterChange(checked ? agent.uid : undefined)}>
                          {agent.displayName}
                        </DropdownMenuCheckboxItem>
                      ))}
                    </DropdownMenuGroup>
                    <DropdownMenuSeparator />
                  </>
                )}
                <DropdownMenuGroup>
                  <DropdownMenuLabel>{t('pod.jobs.filter_kind')}</DropdownMenuLabel>
                  {JOB_KINDS.map(kind => (
                    <DropdownMenuCheckboxItem
                      key={kind}
                      checked={kindFilter === kind}
                      onCheckedChange={checked => onKindFilterChange(checked ? kind : undefined)}>
                      {t(`pod.jobs.kinds.${kind}`)}
                    </DropdownMenuCheckboxItem>
                  ))}
                </DropdownMenuGroup>
                {activeFilterCount > 0 && (
                  <>
                    <DropdownMenuSeparator />
                    <DropdownMenuItem onClick={onClearFilters}>{t('pod.jobs.clear_filters')}</DropdownMenuItem>
                  </>
                )}
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </div>
      )}
    </header>
  )
}
