import { Button, buttonVariants, Sheet, SheetContent, SheetTitle, Textarea } from '@ankole/uikit'
import { RiCloseLine, RiExternalLinkLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { lazy, Suspense, useState, type CSSProperties, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { ErrorBoundary, ErrorFallback } from '../common/error-boundary'
import { podLocation } from '../common/browser-context'
import { updatePodIssue } from './api/generated/sdk.gen'
import { ChatAvatar } from './chat/chat-avatar'
import { ContentError, ContentLoading } from './content-primitives'
import { PodPanelPresence, PodPanelSurface } from './panel-motion'
import { workItemQuery, workItemsQuery, workKeys, type WorkItem } from './work-api'
import './chat.css'

const ChatPage = lazy(() => import('./chat-page').then(module => ({ default: module.ChatPage })))

/**
 * One work item beside the board. The item is its room, so the panel shows the conversation as Chat does, under
 * the one step that a person decides: start the Issue, accept its result, or reopen it. An Issue that has not
 * started shows its request instead, because its room has received nothing yet.
 */
export function IssuePanel({
  id,
  mobile,
  close,
  returnFocus
}: {
  id: string | null
  mobile: boolean
  close(): void
  returnFocus: RefObject<HTMLElement | null>
}) {
  const { t } = useTranslation()
  // Keep the item on the panel until its close transition ends.
  const [displayed, setDisplayed] = useState(id)
  if (id && id !== displayed) setDisplayed(id)
  const shown = id ?? displayed
  const body = shown ? <IssueBody key={shown} id={shown} close={close} /> : null
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

function IssueBody({ id, close }: { id: string; close(): void }) {
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
    mutationFn: (data: { status?: 'started' | 'done'; description?: string }) =>
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
          <Link
            to={podLocation(`/conversations/${id}`).pathname}
            // pod.css gives every data-slot="button" control a 32px touch target on mobile.
            data-slot="button"
            className={buttonVariants({ variant: 'ghost', size: 'icon-xs', className: step ? undefined : 'ml-auto' })}
            aria-label={t('pod.work.open_chat')}
            title={t('pod.work.open_chat')}>
            <RiExternalLinkLine aria-hidden />
          </Link>
          <Button size="icon-xs" variant="ghost" aria-label={t('pod.work.close_issue')} onClick={close}>
            <RiCloseLine aria-hidden />
          </Button>
        </div>
      </header>
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
