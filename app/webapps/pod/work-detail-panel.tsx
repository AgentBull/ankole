import { Button, buttonVariants, Sheet, SheetContent, SheetTitle, Textarea, toast } from '@ankole/uikit'
import { DismissRegular, OpenRegular } from '@ankole/uikit/icons'
import { useMutation, useQuery, useQueryClient, type UseMutationResult } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useEffect, useState, type ReactNode, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { podLocation } from '../common/browser-context'
import { requestErrorMessage } from '../common/request-errors'
import { conversationQuery } from './api'
import { updatePodIssue } from './api/generated/sdk.gen'
import { ExecutionInspectorPanel } from './chat/execution-inspector-panel'
import type { InspectorTarget, LinkedExecution } from './chat/types'
import { contentError } from './content-errors'
import { ContentError, ContentLoading } from './content-primitives'
import { PodPanelSurface, popupOpen, type PanelInputEvent } from './panel-motion'
import { workItemQuery, workItemsQuery, workKeys, type WorkItem } from './work-api'
import './chat.css'

/** The run that the Work page's `run` search parameter names: a card's lead run, or a Job opened from the inspector. */
export type WorkRun = { kind: LinkedExecution['kind']; id: string }

type IssueChange = UseMutationResult<WorkItem, unknown, { status?: 'started' | 'done'; description?: string }>

/**
 * The work item that is open beside the board, drawn as Chat draws a task that a person opens from a conversation.
 * The panel inspects a run of the item's room: the run that the page names, else the item's latest live run, else
 * the room's latest run. An Issue that waits shows its request instead, because its room has received nothing yet.
 * One surface holds every state, so moving between cards or finishing a lookup changes the content in place.
 */
export function WorkDetailPanel({
  id,
  run,
  variant,
  finalFocus,
  close,
  select
}: {
  id: string
  run: WorkRun | null
  variant: 'panel' | 'sheet'
  finalFocus: RefObject<HTMLElement | null>
  close(event?: PanelInputEvent): void
  select(run: WorkRun): void
}) {
  const { t } = useTranslation()
  const items = useQuery(workItemsQuery)
  const listed = items.data?.find(item => item.id === id)
  // A direct link may name an item outside the list, such as an Issue accepted long ago.
  const fetched = useQuery({ ...workItemQuery(id), enabled: items.isSuccess && !listed, retry: false })
  const item = listed ?? fetched.data
  const waiting = !!item?.tracked && item.status === 'todo'
  // Live runs come with the item. The room keeps its ended runs in its conversation detail, which also answers for a
  // room that no longer has an item because its last run ended.
  const lookUp = !run && !waiting && (item ? !item.runs.length : fetched.isError)
  const history = useQuery({ ...conversationQuery(id), enabled: lookUp })
  const change = useIssueChange(id)
  // The request as typed. A start sends it along, so a start right after an edit never loses the edit.
  const [draft, setDraft] = useState<{ id: string; text: string }>()
  const request = draft?.id === id ? draft.text : (item?.description ?? '')
  const runs: LinkedExecution[] = item?.runs.length ? item.runs : (history.data?.linkedRuns ?? [])
  const latest = runs.reduce<LinkedExecution | undefined>(
    (newest, candidate) => (!newest || candidate.createdAt > newest.createdAt ? candidate : newest),
    undefined
  )
  const chosen = waiting ? undefined : (run ?? latest)
  const initialRun = chosen && runs.find(candidate => candidate.kind === chosen.kind && candidate.id === chosen.id)
  const actions = item ? <IssueActions item={item} change={change} request={request} /> : null
  const label = item?.title || initialRun?.title || t('pod.work.issue')

  useEffect(() => {
    if (variant !== 'panel') return
    const escape = (event: KeyboardEvent) => {
      if (event.key !== 'Escape' || event.defaultPrevented || event.isComposing || popupOpen()) return
      const target = event.target instanceof HTMLElement ? event.target : null
      if (target?.closest('[role="dialog"], [role="menu"], [role="listbox"], .pod-chat-find')) return
      event.preventDefault()
      close()
    }
    window.addEventListener('keydown', escape)
    return () => window.removeEventListener('keydown', escape)
  }, [variant, close])

  let body: ReactNode
  if (chosen) {
    const target: InspectorTarget = {
      type: 'execution',
      kind: chosen.kind,
      runID: chosen.id,
      title: initialRun?.title,
      agentName: item?.agent?.name,
      initialRun
    }
    body = (
      <ExecutionInspectorPanel
        key={`${chosen.kind}:${chosen.id}`}
        conversationID={id}
        target={target}
        variant="inline"
        resolveAgentName={uid => (uid === item?.agent?.uid ? item.agent.name : undefined)}
        actions={actions}
        onClose={close}
        onSwitchTarget={next => {
          if (next.type === 'execution') select({ kind: next.kind, id: next.runID })
        }}
      />
    )
  } else {
    const error = (!item && !lookUp && fetched.error) || (lookUp && !history.data && history.error)
    body = (
      <WorkItemBody item={item} actions={actions} close={close}>
        {error ? (
          <ContentError error={error} />
        ) : waiting ? (
          <Textarea
            aria-label={t('pod.work.description')}
            placeholder={t('pod.work.description_placeholder')}
            value={request}
            rows={8}
            onChange={event => setDraft({ id, text: event.target.value })}
            onBlur={() => {
              if (request !== (item.description ?? '')) change.mutate({ description: request })
            }}
          />
        ) : !item || history.isPending ? (
          <ContentLoading immediate />
        ) : (
          <p className="pod-chat-inspector-empty">{t('pod.chat_room.no_background')}</p>
        )}
      </WorkItemBody>
    )
  }

  if (variant === 'sheet') {
    return (
      <Sheet open onOpenChange={open => !open && close()}>
        <SheetContent
          className="pod-chat-inspector-sheet"
          showCloseButton={false}
          closeLabel={t('common.close')}
          finalFocus={finalFocus}>
          <SheetTitle className="sr-only">{label}</SheetTitle>
          {body}
        </SheetContent>
      </Sheet>
    )
  }
  return (
    <PodPanelSurface aria-label={label} className="pod-chat-side-panel pod-chat-inspector-panel">
      {body}
    </PodPanelSurface>
  )
}

/** The inspector's layout for an item without a run to inspect: its title, Agent, and status, then its content. */
function WorkItemBody({
  item,
  actions,
  close,
  children
}: {
  item?: WorkItem
  actions: ReactNode
  close(event?: PanelInputEvent): void
  children: ReactNode
}) {
  const { t } = useTranslation()
  const title = item ? item.title || t('pod.content.untitled') : t('pod.work.issue')
  return (
    <div className="pod-chat-inspector-inner">
      <header className="pod-chat-inspector-header">
        <div className="pod-chat-inspector-title-row">
          <h2 className="pod-chat-inspector-title" title={title}>
            {title}
          </h2>
          {actions}
          <Button
            size="icon-xs"
            variant="ghost"
            aria-label={t('common.close')}
            onClick={event => close(event.nativeEvent)}>
            <DismissRegular aria-hidden />
          </Button>
        </div>
        {item && (
          <div className="pod-chat-inspector-meta">
            {item.agent && <span>{item.agent.name}</span>}
            <span>{t(`pod.work.status.${item.status}`)}</span>
          </div>
        )}
      </header>
      <div className="pod-chat-inspector-scroll">
        <div className="pod-chat-inspector-content">{children}</div>
      </div>
    </div>
  )
}

/** The one step that a person decides for an Issue, then a link to its room. */
function IssueActions({ item, change, request }: { item: WorkItem; change: IssueChange; request: string }) {
  const { t } = useTranslation()
  const step =
    !item.tracked || item.status === 'working' || item.status === 'waiting'
      ? null
      : item.status === 'todo'
        ? (['started', 'pod.work.start'] as const)
        : item.status === 'review'
          ? (['done', 'pod.work.accept'] as const)
          : (['started', 'pod.work.reopen'] as const)
  return (
    <>
      {step && (
        <Button
          size="xs"
          variant={step[0] === 'done' ? 'default' : 'outline'}
          disabled={change.isPending && change.variables.status !== undefined}
          onClick={() =>
            change.mutate({
              status: step[0],
              ...(item.status === 'todo' && request !== (item.description ?? '') ? { description: request } : {})
            })
          }>
          {t(step[1])}
        </Button>
      )}
      <Link
        to={podLocation(`/conversations/${item.id}`).pathname}
        // pod.css gives every data-slot="button" control a 32px touch target on mobile.
        data-slot="button"
        className={buttonVariants({ variant: 'ghost', size: 'icon-xs' })}
        aria-label={t('pod.work.open_chat')}
        title={t('pod.work.open_chat')}>
        <OpenRegular aria-hidden />
      </Link>
    </>
  )
}

function useIssueChange(id: string): IssueChange {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (data: { status?: 'started' | 'done'; description?: string }) =>
      updatePodIssue({ path: { id }, body: { data } }),
    onSuccess: updated => {
      client.setQueryData<WorkItem[]>(workKeys.items, rows => rows?.map(row => (row.id === updated.id ? updated : row)))
      client.setQueryData(workKeys.item(updated.id), updated)
      void client.invalidateQueries({ queryKey: workKeys.all })
    },
    onError: error => void toast.error(requestErrorMessage(contentError(error)))
  })
}
