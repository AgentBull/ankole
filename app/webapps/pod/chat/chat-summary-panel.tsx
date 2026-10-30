import { Button, Switch } from '@ankole/uikit'
import { RiCloseLine } from '@remixicon/react'
import { useTranslation } from 'react-i18next'
import type { ConversationDetail } from '../api'
import { MessagePageReference } from '../message-artifacts'
import { MessageAttachments } from '../chat-attachments'
import { ChatAvatar } from './chat-avatar'
import { ModelControls } from '../model-controls'
import { useRoomActions } from './room-api'
import { LinkedExecutionCard } from './linked-execution-card'
import { PodPanelSurface, type PanelInputEvent } from '../panel-motion'

export function ChatSummaryPanel({
  detail,
  callableAgentUIDs,
  onClose
}: {
  detail: ConversationDetail
  callableAgentUIDs: string[]
  onClose(event?: PanelInputEvent): void
}) {
  const { t } = useTranslation()
  const room = detail.conversation,
    actions = useRoomActions(room.id)
  const { pageIDs, attachments } = detail.artifacts
  return (
    <PodPanelSurface
      className="pod-chat-summary"
      aria-label={t('pod.chat_room.summary')}
      onKeyDown={event => {
        if (
          event.key === 'Escape' &&
          !event.defaultPrevented &&
          !event.nativeEvent.isComposing &&
          !(event.target as HTMLElement).closest('[role="dialog"], [role="menu"], [role="listbox"]')
        ) {
          event.preventDefault()
          event.stopPropagation()
          onClose()
        }
      }}>
      <header>
        <h2>{t('pod.chat_room.summary')}</h2>
        <Button size="icon-sm" variant="ghost" aria-label={t('common.close')} onClick={onClose}>
          <RiCloseLine aria-hidden />
        </Button>
      </header>
      <section>
        <h3>{t('pod.chat_room.agents')}</h3>
        {room.agents.map(agent => (
          <div key={agent.uid} className="pod-chat-summary-agent">
            <div className="pod-chat-member">
              <ChatAvatar name={agent.displayName} src={agent.avatarURL} agent />
              <span>{agent.displayName}</span>
              <span className="pod-chat-subtle">
                {t(agent.active ? 'pod.chat_room.active' : 'pod.chat_room.unavailable')}
              </span>
            </div>
            {agent.active && callableAgentUIDs.includes(agent.uid) && (
              <ModelControls
                agentUID={agent.uid}
                conversationID={room.id}
                draftProfile={null}
                onDraftProfileChange={() => {}}
              />
            )}
            {room.roomMode === 'group' && (
              <label className="pod-chat-member pod-chat-subtle">
                <Switch
                  checked={agent.mayIntervene}
                  aria-label={t('pod.chat_room.intervene_agent', { name: agent.displayName })}
                  disabled={actions.participants.isPending}
                  onCheckedChange={checked =>
                    actions.participants.mutate({ agentUID: agent.uid, mayIntervene: checked })
                  }
                />
                {t('pod.chat_room.intervene')}
              </label>
            )}
          </div>
        ))}
      </section>
      <section>
        <h3>{t('pod.chat_room.people')}</h3>
        {room.participants
          .filter(member => member.type === 'human')
          .map(member => (
            <div className="pod-chat-member" key={member.uid}>
              <ChatAvatar name={member.displayName} src={member.avatarURL} />
              <span>{member.displayName}</span>
              <span className="pod-chat-subtle">{t(`pod.chat_room.role_${member.role || 'member'}`)}</span>
            </div>
          ))}
      </section>
      <section>
        <h3>{t('pod.chat_room.pages_artifacts')}</h3>
        {pageIDs.map(id => (
          <div key={id} className="pod-chat-summary-page">
            <MessagePageReference id={id} />
          </div>
        ))}
        {attachments.map(message => (
          <MessageAttachments
            key={message.messageID}
            conversationID={room.id}
            messageID={message.messageID}
            attachments={message.attachments}
          />
        ))}
        {!pageIDs.length && !attachments.length && <p className="pod-chat-subtle">{t('pod.chat_room.no_pages')}</p>}
      </section>
      <section>
        <h3>{t('pod.chat_room.background')}</h3>
        {detail.linkedRuns.map(run => (
          <LinkedExecutionCard
            key={`${run.kind}:${run.id}`}
            conversationID={room.id}
            run={{
              ...run,
              agentName:
                room.agents.find(agent => agent.uid === run.agentUID)?.displayName ??
                detail.messages.findLast(
                  message => message.authorType === 'agent' && message.authorUID === run.agentUID
                )?.authorDisplayName
            }}
          />
        ))}
        {!detail.linkedRuns.length && <p className="pod-chat-subtle">{t('pod.chat_room.no_background')}</p>}
      </section>
    </PodPanelSurface>
  )
}
