import { useSidebar } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { useCallback, useMemo, useRef, useState } from 'react'
import { useSearchParams } from '../common/router'
import { useSearchDraft } from '../common/use-search-draft'
import { ContentError, ContentLoading } from './content-primitives'
import { JobCreateDialog, type JobStarterPreset } from './job-create-dialog'
import { jobsBoardQuery, jobsError, type JobBoardItem } from './jobs-api'
import { AgentColumnsBoard, EmptyJobsState, FilteredEmptyJobsState, StatusColumnsBoard } from './jobs-board-views'
import { JobsDetailPanel, type JobExecutionRef } from './jobs-detail-panel'
import { JOB_KINDS, JobsBoardHeader, type WorkingAgentSummary } from './jobs-toolbar'
import { PodPanelPresence, usePanelMotion, type PanelInputEvent } from './panel-motion'
import './chat.css'

function parseRunParam(raw: string | null): JobExecutionRef | null {
  if (!raw) return null
  const colon = raw.indexOf(':')
  if (colon <= 0) return null
  const kind = raw.slice(0, colon)
  const id = raw.slice(colon + 1).trim()
  if (!id) return null
  if (kind === 'background_agent_job' || kind === 'workflow') return { kind, id }
  return null
}

function matchesSearchQuery(item: JobBoardItem, normalizedQuery: string): boolean {
  if (!normalizedQuery) return true
  const haystacks = [
    item.title,
    item.summary,
    item.agentName,
    item.agentUID,
    item.pageTitle,
    item.conversationTitle,
    item.triggerSummary
  ]
  return haystacks.some(field => field?.toLowerCase().includes(normalizedQuery))
}

export function JobsRoute() {
  const { isMobile } = useSidebar()
  const [searchParams, setSearchParams] = useSearchParams()
  const board = useQuery(jobsBoardQuery)

  const selectedID = searchParams.get('item')?.trim() || undefined
  const selectedRun = useMemo(() => parseRunParam(searchParams.get('run')), [searchParams])
  const agentFilter = searchParams.get('agent')?.trim() || undefined
  const rawKind = searchParams.get('kind')?.trim()
  const kindFilter =
    rawKind && (JOB_KINDS as readonly string[]).includes(rawKind) ? (rawKind as JobBoardItem['kind']) : undefined
  const searchQuery = searchParams.get('q') ?? ''
  const viewMode: 'status' | 'agent' = searchParams.get('view') === 'agent' ? 'agent' : 'status'

  const [inputQuery, setInputQuery] = useSearchDraft(
    searchQuery,
    value => {
      const clean = value.trim()
      setSearchParams(
        prev => {
          const next = new URLSearchParams(prev)
          if (clean) next.set('q', clean)
          else next.delete('q')
          return next
        },
        { replace: true, preventScrollReset: true }
      )
    },
    { delay: 140 }
  )

  const panelMotion = usePanelMotion(Boolean(selectedID))
  const triggerElement = useRef<HTMLElement | null>(null)
  const createButtonRef = useRef<HTMLButtonElement | null>(null)

  const [createOpen, setCreateOpen] = useState(false)
  const [starterPreset, setStarterPreset] = useState<JobStarterPreset | null>(null)

  const selectCard = useCallback(
    (nextID: string | undefined, event?: PanelInputEvent, source?: HTMLElement | null) => {
      if (source) triggerElement.current = source
      panelMotion.prepare(Boolean(nextID), event)
      setSearchParams(
        prev => {
          const next = new URLSearchParams(prev)
          if (nextID) {
            next.set('item', nextID)
          } else {
            next.delete('item')
          }
          next.delete('run')
          return next
        },
        { replace: !nextID, preventScrollReset: true }
      )
    },
    [panelMotion, setSearchParams]
  )

  const selectRun = useCallback(
    (nextRun: JobExecutionRef | null) => {
      setSearchParams(
        prev => {
          const next = new URLSearchParams(prev)
          if (nextRun) {
            next.set('run', `${nextRun.kind}:${nextRun.id}`)
          } else {
            next.delete('run')
          }
          return next
        },
        { replace: true, preventScrollReset: true }
      )
    },
    [setSearchParams]
  )

  const updateParam = useCallback(
    (key: string, value: string | undefined) => {
      setSearchParams(
        prev => {
          const next = new URLSearchParams(prev)
          if (value) next.set(key, value)
          else next.delete(key)
          return next
        },
        { replace: true, preventScrollReset: true }
      )
    },
    [setSearchParams]
  )

  const clearFilters = useCallback(() => {
    setInputQuery('')
    setSearchParams(
      prev => {
        const next = new URLSearchParams(prev)
        next.delete('agent')
        next.delete('kind')
        next.delete('q')
        return next
      },
      { replace: true, preventScrollReset: true }
    )
  }, [setInputQuery, setSearchParams])

  const allItems = board.data?.items ?? []
  const agents = board.data?.agents ?? []
  const normalizedQuery = inputQuery.trim().toLowerCase()

  const filteredItems = useMemo(
    () =>
      allItems.filter(item => {
        if (agentFilter && item.agentUID !== agentFilter) return false
        if (kindFilter && item.kind !== kindFilter) return false
        if (normalizedQuery && !matchesSearchQuery(item, normalizedQuery)) return false
        return true
      }),
    [agentFilter, allItems, kindFilter, normalizedQuery]
  )

  const selectedItem = useMemo(
    () => (selectedID ? allItems.find(item => item.id === selectedID) : undefined),
    [allItems, selectedID]
  )

  const agentAvatarByUID = useMemo(() => new Map(agents.map(agent => [agent.uid, agent.avatarURL])), [agents])

  const workingAgents = useMemo(() => {
    const byUID = new Map<string, WorkingAgentSummary>()
    for (const item of allItems) {
      if (item.column !== 'running' || item.attention || !item.agentUID) continue
      if (!byUID.has(item.agentUID)) {
        const candidate = agents.find(agent => agent.uid === item.agentUID)
        byUID.set(item.agentUID, {
          uid: item.agentUID,
          name: item.agentName || candidate?.displayName || `@${item.agentUID}`,
          avatarURL: candidate?.avatarURL
        })
      }
    }
    return [...byUID.values()]
  }, [agents, allItems])

  const attentionCount = useMemo(() => allItems.filter(item => item.attention).length, [allItems])
  const activeFilterCount = (agentFilter ? 1 : 0) + (kindFilter ? 1 : 0)
  const hasAnyFilter = activeFilterCount > 0 || normalizedQuery.length > 0
  const showToolbar = !board.isPending && !board.error && (allItems.length > 0 || hasAnyFilter)
  const filteredAgentName = useMemo(
    () =>
      agentFilter ? (agents.find(agent => agent.uid === agentFilter)?.displayName ?? `@${agentFilter}`) : undefined,
    [agentFilter, agents]
  )

  const openCreateWithPreset = useCallback((preset: JobStarterPreset | null) => {
    setStarterPreset(preset)
    setCreateOpen(true)
  }, [])

  return (
    <div className="pod-chat-room-body h-full overflow-hidden">
      <div className="pod-chat-room-main flex flex-col overflow-y-auto px-5 py-5 md:px-8 md:py-6">
        <JobsBoardHeader
          agents={agents}
          workingAgents={workingAgents}
          attentionCount={attentionCount}
          showToolbar={showToolbar}
          viewMode={viewMode}
          agentFilter={agentFilter}
          filteredAgentName={filteredAgentName}
          kindFilter={kindFilter}
          inputQuery={inputQuery}
          activeFilterCount={activeFilterCount}
          createButtonRef={createButtonRef}
          onNewJob={() => openCreateWithPreset(null)}
          onViewModeChange={next => updateParam('view', next === 'agent' ? 'agent' : undefined)}
          onAgentFilterChange={next => updateParam('agent', next)}
          onKindFilterChange={next => updateParam('kind', next)}
          onQueryChange={setInputQuery}
          onClearFilters={clearFilters}
        />

        {(() => {
          if (board.isPending) return <ContentLoading className="flex-1 py-16" />
          if (board.error) return <ContentError error={jobsError(board.error)} retry={() => void board.refetch()} />
          if (allItems.length === 0) return <EmptyJobsState agents={agents} onPickPreset={openCreateWithPreset} />
          if (filteredItems.length === 0) return <FilteredEmptyJobsState onReset={clearFilters} />
          if (viewMode === 'agent') {
            return (
              <AgentColumnsBoard
                items={filteredItems}
                agents={agents}
                selectedID={selectedID}
                onSelect={selectCard}
                onQuickCreate={openCreateWithPreset}
              />
            )
          }
          return (
            <StatusColumnsBoard
              items={filteredItems}
              agents={agents}
              agentAvatarByUID={agentAvatarByUID}
              selectedID={selectedID}
              onSelect={selectCard}
              onQuickCreate={openCreateWithPreset}
            />
          )
        })()}
      </div>

      {isMobile ? (
        selectedID ? (
          <JobsDetailPanel
            id={selectedID}
            run={selectedRun}
            item={selectedItem}
            agents={agents}
            variant="sheet"
            finalFocus={triggerElement}
            close={event => selectCard(undefined, event)}
            selectRun={selectRun}
          />
        ) : null
      ) : (
        <PodPanelPresence animate={panelMotion.animate}>
          {selectedID ? (
            <JobsDetailPanel
              key="jobs-detail"
              id={selectedID}
              run={selectedRun}
              item={selectedItem}
              agents={agents}
              variant="panel"
              finalFocus={triggerElement}
              close={event => selectCard(undefined, event)}
              selectRun={selectRun}
            />
          ) : null}
        </PodPanelPresence>
      )}

      <JobCreateDialog
        open={createOpen}
        onOpenChange={setCreateOpen}
        agents={agents}
        preset={starterPreset}
        returnFocus={createButtonRef}
        onCreated={created => selectCard(created.id)}
      />
    </div>
  )
}
