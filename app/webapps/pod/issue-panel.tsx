import { Badge, Button, buttonVariants, Input, Sheet, SheetContent, SheetTitle, Textarea } from '@ankole/uikit'
import {
  RiAddLine,
  RiCloseLine,
  RiExternalLinkLine,
  RiFlashlightLine,
  RiGitBranchLine,
  RiPauseLine,
  RiPlayLine,
  RiRepeatLine
} from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { lazy, Suspense, useState, type CSSProperties, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { formatDateTime } from '../common/date-time'
import { ErrorBoundary, ErrorFallback } from '../common/error-boundary'
import { podLocation } from '../common/browser-context'
import { changePodScheduledWork, updatePodIssue } from './api/generated/sdk.gen'
import { ChatAvatar } from './chat/chat-avatar'
import { ContentError, ContentLoading } from './content-primitives'
import { parseLabels } from './issue-create-dialog'
import { PodPanelPresence, PodPanelSurface } from './panel-motion'
import { workItemQuery, workItemsQuery, workKeys, type WorkItem } from './work-api'
import './chat.css'

const ChatPage = lazy(() => import('./chat-page').then(module => ({ default: module.ChatPage })))

/**
 * One work item beside the board. The item is its room, so the panel shows the conversation as Chat does, under
 * the one step that a person decides: start the Issue, accept its result, or reopen it. An Issue that has not
 * started shows its request instead, because its room has received nothing yet. A line under the header holds the
 * Issue's labels and the schedule on which it repeats.
 */
export function IssuePanel({
  id,
  mobile,
  close,
  returnFocus,
  newSubIssue
}: {
  id: string | null
  mobile: boolean
  close(): void
  returnFocus: RefObject<HTMLElement | null>
  newSubIssue(item: WorkItem): void
}) {
  const { t } = useTranslation()
  // Keep the item on the panel until its close transition ends.
  const [displayed, setDisplayed] = useState(id)
  if (id && id !== displayed) setDisplayed(id)
  const shown = id ?? displayed
  const body = shown ? <IssueBody key={shown} id={shown} close={close} newSubIssue={newSubIssue} /> : null
  if (mobile) {
    return (
      <Sheet open={!!id} onOpenChange={open => !open && close()}>
        <SheetContent className="pod-page-chat-sheet" showCloseButton={false} finalFocus={returnFocus}>
          <SheetTitle className="sr-only">{t('pod.work.issue')}</SheetTitle>
          {body}
        </SheetContent>
      </Sheet>
    )
  }
  return (
    <PodPanelPresence animate>
      {id && (
        <PodPanelSurface
          key="issue"
          aria-label={t('pod.work.issue')}
          data-sheet
          className="pod-page-chat paper-sheet"
          style={{ '--pod-page-chat-width': '560px' } as CSSProperties}>
          {body}
        </PodPanelSurface>
      )}
    </PodPanelPresence>
  )
}

function IssueBody({ id, close, newSubIssue }: { id: string; close(): void; newSubIssue(item: WorkItem): void }) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const items = useQuery(workItemsQuery)
  const listed = items.data?.find(item => item.id === id)
  // A direct link may name an Issue outside the list, such as one accepted long ago.
  const fetched = useQuery({ ...workItemQuery(id), enabled: items.isSuccess && !listed, retry: false })
  const item = listed ?? fetched.data
  // The request as typed. A start sends it along, so a start right after an edit never loses the edit.
  const [draft, setDraft] = useState<string>()
  const request = draft ?? item?.description ?? ''
  const change = useMutation({
    mutationFn: (data: { status?: 'started' | 'done'; description?: string; labels?: string[] }) =>
      updatePodIssue({ path: { id }, body: { data } }),
    onSuccess: updated => {
      client.setQueryData<WorkItem[]>(workKeys.items, rows => rows?.map(row => (row.id === updated.id ? updated : row)))
      client.setQueryData(workKeys.item(id), updated)
      void client.invalidateQueries({ queryKey: workKeys.all })
    }
  })
  const step =
    !item?.tracked || item.status === 'working' || item.status === 'waiting'
      ? null
      : item.status === 'todo'
        ? (['started', 'pod.work.start'] as const)
        : item.status === 'review'
          ? (['done', 'pod.work.accept'] as const)
          : (['started', 'pod.work.reopen'] as const)
  return (
    <>
      <header className="pod-page-chat-header">
        <div className="sheet-header gap-1">
          <h2 className="sheet-title">{item ? t(`pod.work.status.${item.status}`) : t('pod.work.issue')}</h2>
          {step && (
            <Button
              size="xs"
              variant={step[0] === 'done' ? 'default' : 'outline'}
              className="ml-auto"
              disabled={change.isPending && change.variables.status !== undefined}
              onClick={() =>
                change.mutate({
                  status: step[0],
                  ...(item?.status === 'todo' && request !== (item.description ?? '') ? { description: request } : {})
                })
              }>
              {t(step[1])}
            </Button>
          )}
          {item?.tracked && (
            <Button
              size="icon-xs"
              variant="ghost"
              className={step ? undefined : 'ml-auto'}
              aria-label={t('pod.work.new_sub_issue')}
              title={t('pod.work.new_sub_issue')}
              onClick={() => newSubIssue(item)}>
              <RiGitBranchLine aria-hidden />
            </Button>
          )}
          <Link
            to={podLocation(`/conversations/${id}`).pathname}
            // pod.css gives every data-slot="button" control a 32px touch target on mobile.
            data-slot="button"
            className={buttonVariants({
              variant: 'ghost',
              size: 'icon-xs',
              className: step || item?.tracked ? undefined : 'ml-auto'
            })}
            aria-label={t('pod.work.open_chat')}
            title={t('pod.work.open_chat')}>
            <RiExternalLinkLine aria-hidden />
          </Link>
          <Button size="icon-xs" variant="ghost" aria-label={t('pod.work.close_issue')} onClick={close}>
            <RiCloseLine aria-hidden />
          </Button>
        </div>
      </header>
      {item?.tracked && (
        <IssueAttributes item={item} relabel={labels => change.mutate({ labels })} busy={change.isPending} />
      )}
      {item?.tracked && item.status === 'todo' ? (
        // An Issue that waits has sent nothing, so the panel shows its request and no conversation to write in.
        <div className="grid min-h-0 flex-1 content-start gap-3 overflow-auto px-[18px] pb-4 text-[13px] leading-5">
          <h3 className="text-base font-medium break-words">{item.title || t('pod.content.untitled')}</h3>
          {item.agent && (
            <p className="flex items-center gap-2 text-xs text-fg-secondary">
              <ChatAvatar name={item.agent.name} agent className="size-5" />
              <span className="min-w-0 truncate">{item.agent.name}</span>
            </p>
          )}
          <Textarea
            aria-label={t('pod.work.description')}
            placeholder={t('pod.work.description_placeholder')}
            value={request}
            rows={8}
            onChange={event => setDraft(event.target.value)}
            onBlur={() => {
              if (request !== (item.description ?? '')) change.mutate({ description: request })
            }}
          />
          <ContentError error={change.error} />
        </div>
      ) : (
        <>
          {change.error && (
            <div className="shrink-0 border-b border-border px-[18px] pb-4">
              <ContentError error={change.error} />
            </div>
          )}
          <ErrorBoundary
            resetKeys={[id]}
            fallback={({ error, reset }) => (
              <div className="p-4">
                <ErrorFallback variant="panel" error={error} reset={reset} />
              </div>
            )}>
            <Suspense fallback={<ContentLoading label={t('pod.chat.loading_history')} immediate />}>
              <ChatPage
                key={id}
                conversationID={id}
                onExitConversation={() => {
                  void client.invalidateQueries({ queryKey: workKeys.all })
                  close()
                }}
              />
            </Suspense>
          </ErrorBoundary>
        </>
      )}
    </>
  )
}

/** The Issue's labels, its parent, and the schedule on which it repeats, in one line under the panel's header. */
function IssueAttributes({ item, relabel, busy }: { item: WorkItem; relabel(labels: string[]): void; busy: boolean }) {
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const [adding, setAdding] = useState<string>()
  const schedule = useMutation({
    mutationFn: (change: 'pause' | 'resume' | 'run') =>
      changePodScheduledWork({ path: { id: item.repeat!.id }, body: { data: { change } } }),
    onSettled: () => void client.invalidateQueries({ queryKey: workKeys.all })
  })
  const add = () => {
    const labels = parseLabels(adding ?? '')
    setAdding(undefined)
    if (labels.length) relabel([...new Set([...item.labels, ...labels])])
  }
  return (
    <div className="flex shrink-0 flex-wrap items-center gap-x-3 gap-y-1.5 px-[18px] pb-3 text-xs text-fg-secondary">
      {item.parent && (
        <Link
          className="truncate hover:underline"
          to="."
          search={(current: Record<string, unknown>) => ({ ...current, issue: item.parent!.id })}>
          {t('pod.work.parent_label', { title: item.parent.title || t('pod.content.untitled') })}
        </Link>
      )}
      {item.children && <span className="tabular-nums">{t('pod.work.sub_issues', item.children)}</span>}
      <span className="flex flex-wrap items-center gap-1" aria-label={t('pod.work.labels')} role="group">
        {item.labels.map(label => (
          <Badge key={label} size="sm" className="gap-0.5 pr-0.5">
            {label}
            <button
              type="button"
              className="rounded-mini px-0.5 hover:bg-accent focus-visible:outline-2 focus-visible:outline-ring"
              aria-label={t('pod.work.remove_label', { label })}
              disabled={busy}
              onClick={() => relabel(item.labels.filter(value => value !== label))}>
              <RiCloseLine aria-hidden className="size-3" />
            </button>
          </Badge>
        ))}
        {adding === undefined ? (
          <Button size="xs" variant="ghost" disabled={busy || item.labels.length >= 10} onClick={() => setAdding('')}>
            <RiAddLine aria-hidden />
            {t('pod.work.add_label')}
          </Button>
        ) : (
          <Input
            autoFocus
            className="h-6 w-40 text-xs"
            aria-label={t('pod.work.add_label')}
            placeholder={t('pod.work.labels_placeholder')}
            value={adding}
            onChange={event => setAdding(event.target.value)}
            onBlur={add}
            onKeyDown={event => {
              if (event.key === 'Enter' && !event.nativeEvent.isComposing) {
                event.preventDefault()
                add()
              }
              if (event.key === 'Escape') setAdding(undefined)
            }}
          />
        )}
      </span>
      {item.repeat && (
        <span className="ml-auto inline-flex items-center gap-1">
          <RiRepeatLine aria-label={t('pod.work.repeats')} className="size-3.5" />
          {item.repeat.status === 'paused'
            ? t('pod.work.paused')
            : item.repeat.dueAt && t('pod.work.next_run', { time: formatDateTime(item.repeat.dueAt, i18n.language) })}
          {item.repeat.manageable && (
            <>
              <Button
                size="icon-xs"
                variant="ghost"
                disabled={schedule.isPending}
                aria-label={t(item.repeat.status === 'paused' ? 'pod.work.resume' : 'pod.work.pause')}
                title={t(item.repeat.status === 'paused' ? 'pod.work.resume' : 'pod.work.pause')}
                onClick={() => schedule.mutate(item.repeat!.status === 'paused' ? 'resume' : 'pause')}>
                {item.repeat.status === 'paused' ? <RiPlayLine aria-hidden /> : <RiPauseLine aria-hidden />}
              </Button>
              <Button
                size="icon-xs"
                variant="ghost"
                disabled={schedule.isPending}
                aria-label={t('pod.work.run_now')}
                title={t('pod.work.run_now')}
                onClick={() => schedule.mutate('run')}>
                <RiFlashlightLine aria-hidden />
              </Button>
            </>
          )}
        </span>
      )}
      <ContentError error={schedule.error} />
    </div>
  )
}
