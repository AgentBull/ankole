import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { ChatDrafts } from './state/chat-drafts'
import { useSignals } from '@preact/signals-react/runtime'
import { useTranslation } from 'react-i18next'
import { ChatAttachmentDrafts } from './chat-attachments'
import { Button } from '@ankole/uikit'
import type { ChatModel } from './state/chat'
import type { ChatAttachments } from './state/chat-attachments'

const DraftContext = createContext<ChatDrafts | null>(null)

export function ChatDraftProvider({ children }: { children: ReactNode }) {
  const [drafts] = useState(() => new ChatDrafts())
  useEffect(() => {
    const protectDrafts = (event: BeforeUnloadEvent) => {
      if (drafts.hasUnsentWork()) event.preventDefault()
    }
    window.addEventListener('beforeunload', protectDrafts)
    return () => {
      window.removeEventListener('beforeunload', protectDrafts)
      drafts.dispose()
    }
  }, [drafts])
  return <DraftContext value={drafts}>{children}</DraftContext>
}

export function useChatDrafts() {
  const drafts = useContext(DraftContext)
  if (!drafts) throw new Error('Pod chat draft provider is missing')
  return drafts
}

export function useChatDraft(conversationID?: string, pageID?: string) {
  const drafts = useChatDrafts()
  const [selection, setSelection] = useState<string>()
  const model = useMemo(
    () => drafts.get(!conversationID && !pageID ? selection : conversationID, conversationID ? undefined : pageID),
    [drafts, conversationID, pageID, selection]
  )
  return { drafts, model, selectDraft: setSelection }
}

export function UnconfirmedChats({
  current,
  select
}: {
  current: InstanceType<typeof ChatModel>
  select(id: string): void
}) {
  useSignals()
  const drafts = useChatDrafts()
    .unconfirmedStandalone()
    .filter(entry => entry.model !== current)
  return (
    <LocalChatDrafts
      drafts={drafts.map(({ id, model }) => ({
        key: id,
        text: model.draft.value || model.pending.value?.text || '',
        attachments: model.attachments
      }))}
      restore={select}
    />
  )
}

/** Recovery reads only local drafts and Files, never remote Page or Chat data. */
export function LocalPageChatDrafts({ pageID }: { pageID: string }) {
  useSignals()
  const owner = useChatDrafts()
  const drafts = owner.localPageDrafts(pageID)
  return (
    <>
      <LocalChatDrafts drafts={drafts} />
      {owner.localPageAttachments(pageID).map((model, index) => (
        <ChatAttachmentDrafts key={index} model={model} recovery />
      ))}
    </>
  )
}

export function LocalChatDrafts({
  drafts,
  restore
}: {
  drafts: { key: string; text: string; attachments?: ChatAttachments }[]
  restore?(key: string): void
}) {
  const { t } = useTranslation()
  if (!drafts.length) return null
  return (
    <section aria-label={t('pod.chat_drafts.title')} className="mt-4 space-y-3 rounded-md border border-border p-4">
      <h2 className="text-sm font-medium">{t('pod.chat_drafts.title')}</h2>
      <p className="text-sm text-fg-tertiary">{t('pod.chat_drafts.recovery_hint')}</p>
      {drafts.map((draft, index) => (
        <div key={draft.key} className="grid gap-2 text-sm">
          <label className="grid gap-2">
            <span>{t('pod.chat_drafts.message', { number: index + 1 })}</span>
            <textarea
              readOnly
              value={draft.text}
              rows={4}
              className="w-full resize-y rounded-md border border-border bg-background p-3"
            />
          </label>
          {draft.attachments && <ChatAttachmentDrafts model={draft.attachments} recovery />}
          {restore && (
            <Button variant="outline" size="sm" onClick={() => restore(draft.key)}>
              {t('pod.content.restore')}
            </Button>
          )}
        </div>
      ))}
    </section>
  )
}
