import { usePageMetadata } from '../use-page-metadata'
import {
  Button,
  InputGroup,
  InputGroupAddon,
  InputGroupButton,
  InputGroupTextarea,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  toast
} from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import {
  RiArrowUpLine,
  RiCheckLine,
  RiCloseLine,
  RiStopFill,
  RiAtLine,
  RiCommandLine,
  RiLoader4Line
} from '@remixicon/react'
import { useEffect, useId, useImperativeHandle, useLayoutEffect, useRef, useState, type RefObject } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { podLocation } from '../../common/browser-context'
import type { ChatModel } from '../state/chat'
import { shouldSendOnEnter, hasDraftMention } from '../state/chat'
import type { ChatCommands } from '../chat-commands'
import type { ConversationDetail, PodAgent } from '../api'
import {
  ChatAttachmentButton,
  ChatAttachmentDrafts,
  MessageAttachments,
  chatAttachmentHandlers
} from '../chat-attachments'
import { ModelControls } from '../model-controls'
import { pageQuery } from '../content-api'
import { MentionPicker, type MentionChoice } from './mention-picker'
import { SlashCommandPicker, type SlashCommand } from './slash-command-picker'
import {
  completionAt,
  insertCompletionTrigger,
  type ComposerCompletion,
  type CompletionHandle
} from './composer-completion'
import type { ClarifyAnswer } from './choice-card'

type Model = InstanceType<typeof ChatModel>
export function Composer({
  model,
  agents,
  agentsLoaded,
  personalAssistant = false,
  agentUID,
  detail,
  commands,
  variant = 'compact',
  onInvite,
  onRename,
  onSummary,
  onNew,
  inputRef,
  answering,
  onAnswer
}: {
  model: Model
  agents: PodAgent[]
  agentsLoaded: boolean
  personalAssistant?: boolean
  agentUID: string
  detail?: ConversationDetail
  commands: ChatCommands
  variant?: 'hero' | 'compact'
  onInvite(): void
  onRename(): void
  onSummary(): void
  onNew?(): void
  inputRef?: RefObject<HTMLTextAreaElement | null>
  answering: boolean
  onAnswer?(interactionID: string, answer: ClarifyAnswer): Promise<ConversationDetail>
}) {
  useSignals()
  const { t } = useTranslation(),
    navigate = useNavigate()
  const shell = useRef<HTMLDivElement>(null)
  const textarea = useRef<HTMLTextAreaElement>(null)
  const pendingCaret = useRef<number>(undefined)
  const [modelOpen, setModelOpen] = useState(false)
  const recipientControl = useRef<HTMLButtonElement>(null)
  useImperativeHandle(inputRef, () => textarea.current!, [])
  const [picker, setPicker] = useState<ComposerCompletion>()
  const pickerRef = useRef<ComposerCompletion>(undefined)
  const updatePicker = (next: ComposerCompletion | undefined) => {
    pickerRef.current = next
    setPicker(next)
  }
  const completion = useRef<CompletionHandle>(null)
  const completionID = useId()
  const composing = useRef(false)
  const dismissedSlash = useRef<number | undefined>(undefined)
  useEffect(() => {
    if (!picker) return
    const outside = (event: PointerEvent) => {
      if (!shell.current?.contains(event.target as Node)) updatePicker(undefined)
    }
    document.addEventListener('pointerdown', outside)
    return () => document.removeEventListener('pointerdown', outside)
  }, [picker])
  const { disabled, sending, submit, working, stop, canSubmit } = commands
  const conversationID = detail?.conversation.id
  const callable = new Set(agents.map(agent => agent.uid))
  const answerID = model.answeringInteractionID.value
  const answerQuestion = detail?.pendingInteractions.find(question => question.interaction_id === answerID)
  const answerAvailable =
    !!answerQuestion &&
    answerQuestion.state === 'pending' &&
    !!answerQuestion.agentUID &&
    callable.has(answerQuestion.agentUID) &&
    !!detail?.conversation.agents.some(agent => agent.uid === answerQuestion.agentUID && agent.active)
  const roomAgents = (detail?.conversation.agents ?? agents).filter(agent => agent.active && callable.has(agent.uid))
  const group = detail?.conversation.roomMode === 'group'
  const humanOnly = detail?.conversation.accessScope === 'anchor_page' && roomAgents.length === 0
  const recipientUID =
    answerQuestion?.agentUID ??
    model.editing.value?.agentUID ??
    (conversationID
      ? model.targetAgentUID.value ||
        (group || humanOnly ? '__listeners__' : (detail?.conversation.agents[0]?.uid ?? null))
      : agentUID || null)
  const recipientAgentUIDs = roomAgents.map(agent => agent.uid)
  // Keep an unavailable selection visible until the user chooses another recipient.
  if (recipientUID && recipientUID !== '__listeners__' && !recipientAgentUIDs.includes(recipientUID)) {
    recipientAgentUIDs.push(recipientUID)
  }
  const recipientNames = new Map(
    [...(detail?.conversation.agents ?? []), ...agents].map(agent => [agent.uid, agent.displayName])
  )
  const selectedTargetUnavailable = !commands.recipientAvailable
  const restricted =
    agentsLoaded &&
    !humanOnly &&
    detail?.conversation.roomMode === 'dm' &&
    detail.conversation.agents.some(agent => agent.active && !callable.has(agent.uid))
  const modelAgentUID = !selectedTargetUnavailable
    ? recipientUID && roomAgents.some(agent => agent.uid === recipientUID)
      ? recipientUID
      : roomAgents.length === 1
        ? roomAgents[0]!.uid
        : undefined
    : undefined
  const editingID = model.editing.value?.messageID
  useEffect(() => {
    if (editingID) textarea.current?.focus()
  }, [editingID])
  const draft = model.draft.value
  useLayoutEffect(() => {
    const cursor = pendingCaret.current
    if (cursor === undefined) return
    pendingCaret.current = undefined
    textarea.current?.focus()
    textarea.current?.setSelectionRange(cursor, cursor)
  }, [draft, picker])
  useEffect(() => {
    if (CSS.supports('field-sizing', 'content')) return
    const input = textarea.current
    if (input) {
      input.style.height = 'auto'
      input.style.height = `${Math.min(input.scrollHeight, 240)}px`
    }
  }, [draft])
  const close = () => {
    const active = pickerRef.current
    if (active?.kind === 'slash') dismissedSlash.current = active.start
    updatePicker(undefined)
    textarea.current?.focus()
  }
  const leaveAnswer = () => {
    model.cancelAnswer()
    textarea.current?.focus()
  }
  const syncPicker = (input: HTMLTextAreaElement) => {
    if (composing.current) return
    const active = pickerRef.current
    const next = completionAt(input.value, input.selectionStart, input.selectionEnd, active)
    if (next?.kind === 'slash' && next.start === dismissedSlash.current) {
      updatePicker(undefined)
      return
    }
    if (next?.kind !== 'slash') dismissedSlash.current = undefined
    updatePicker(next && active?.kind === 'page' && next.start === active.start ? { ...next, kind: 'page' } : next)
  }
  const open = (kind: ComposerCompletion['kind'], atPosition?: number, baseValue?: string) => {
    dismissedSlash.current = undefined
    const value = baseValue ?? model.draft.value
    const start = atPosition ?? textarea.current?.selectionStart ?? value.length
    const end = atPosition ?? textarea.current?.selectionEnd ?? start
    const inserted = insertCompletionTrigger(value, start, end, kind)
    pendingCaret.current = inserted.cursor
    model.draft.value = inserted.value
    updatePicker(inserted.completion)
  }
  const choose = (choice: MentionChoice) => {
    const text = `@${choice.displayName}`
    const start = picker?.start ?? draft.length,
      end = picker?.end ?? start
    pendingCaret.current = start + text.length + 1
    model.draft.value = `${draft.slice(0, start)}${text} ${draft.slice(end)}`
    if (choice.type === 'page') {
      model.referencePage(choice.uid)
    } else {
      model.mentions.value = [
        ...model.mentions.value.filter(mention => mention.uid !== choice.uid),
        { type: choice.type, uid: choice.uid, displayName: choice.displayName }
      ]
    }
    if (!detail && !personalAssistant && choice.type === 'agent' && !model.selectedAgentUID.value) {
      model.selectedAgentUID.value = choice.uid
    }
    close()
  }
  const slash = (command: SlashCommand) => {
    const start = picker?.start
    const nextDraft = picker ? draft.slice(0, picker.start) + draft.slice(picker.end) : draft
    if (picker) model.draft.value = nextDraft
    close()
    if (command === 'new') {
      if (onNew) onNew()
      else void navigate({ to: podLocation('/').pathname })
    } else if (command === 'invite') onInvite()
    else if (command === 'rename') onRename()
    else if (command === 'page') open('page', start ?? nextDraft.length, nextDraft)
    else if (command === 'model') {
      if (modelAgentUID) setModelOpen(true)
      else onSummary()
    } else if (command === 'stop') stop()
  }
  const send = () => {
    if (sending || answering || !canSubmit || (answerID && !answerAvailable)) return
    updatePicker(undefined)
    if (model.editing.value) {
      submit()
      return
    }
    model.mentions.value = model.mentions.value.filter(mention =>
      hasDraftMention(model.draft.value, mention.displayName)
    )
    if (onAnswer && answerID && answerAvailable) {
      const capture = {
        text: model.draft.value,
        links: model.links.value,
        mentions: model.mentions.value,
        ...model.attachments.capture()
      }
      void onAnswer(answerID, {
        text: capture.text,
        links: capture.links,
        mentions: capture.mentions.filter(mention => mention.type === 'human'),
        attachments: capture.attachments
      })
        .then(result => {
          model.answerAccepted(answerID, capture)
          model.neededInvites.value = capture.mentions
            .filter(
              mention =>
                mention.type === 'human' && !result.conversation.participants.some(member => member.uid === mention.uid)
            )
            .map(({ uid, displayName }) => ({ uid, displayName }))
        })
        .catch(error => model.attachments.rejected(error, capture.attachmentIDs))
    } else submit()
  }
  const unavailable = detail?.conversation.agents.filter(agent => !agent.active) ?? []
  const quoted = model.quoted.value
  const editing = model.editing.value
  const editedAttachments =
    editing &&
    (detail?.pendingQueues
      .find(queue => queue.agentUID === editing.agentUID)
      ?.inputs.find(input => input.messageID === editing.messageID)?.attachments ??
      detail?.messages.find(message => message.id === editing.messageID)?.attachments)
  return (
    <div ref={shell} className={`pod-chat-composer-shell pod-chat-composer-${variant}`}>
      {!answerID && (!!unavailable.length || restricted || selectedTargetUnavailable) && (
        <div className="pod-chat-agent-banner" role="status">
          {selectedTargetUnavailable
            ? t('pod.chat_room.recipient_unavailable')
            : restricted
              ? t('pod.chat_room.invoke_unavailable')
              : `${unavailable.map(agent => agent.displayName).join(', ')} · ${t('pod.chat.agent_unavailable')}`}
          <Button
            size="xs"
            variant="ghost"
            onClick={
              selectedTargetUnavailable
                ? model.editing.value
                  ? () => model.cancelEdit()
                  : () => recipientControl.current?.click()
                : onInvite
            }>
            {t(
              selectedTargetUnavailable
                ? model.editing.value
                  ? 'pod.chat.cancel_pending'
                  : 'pod.chat.choose_agent'
                : 'pod.chat_room.manage_agents'
            )}
          </Button>
        </div>
      )}
      {picker?.kind === 'slash' ? (
        <SlashCommandPicker
          existing={!!detail}
          working={working}
          hasAgents={roomAgents.length > 0}
          query={picker.query}
          id={completionID}
          input={textarea}
          handle={completion}
          onChoose={slash}
          onClose={close}
        />
      ) : (
        picker && (
          <MentionPicker
            detail={detail}
            pagesOnly={picker.kind === 'page' || !!model.editing.value}
            allowAgents={!answerID}
            query={picker.query}
            id={completionID}
            input={textarea}
            handle={completion}
            onChoose={choose}
            onClose={close}
          />
        )
      )}
      <form
        {...chatAttachmentHandlers(
          model.attachments,
          disabled || !!model.editing.value,
          model.editing.value
            ? () =>
                toast.info(
                  t('pod.chat.attachments_disabled_while_editing', {
                    defaultValue: 'Finish or cancel editing before adding files.'
                  })
                )
            : undefined
        )}
        className="pod-chat-composer"
        onSubmit={event => {
          event.preventDefault()
          send()
        }}>
        <InputGroup variant="paper" className="pod-chat-composer-field">
          {answerID && (
            <div className="pod-chat-answer-context" role="status">
              <div>
                <strong>
                  {t(
                    answerAvailable
                      ? 'pod.chat_timeline.answer_context'
                      : answerQuestion
                        ? 'pod.chat_timeline.answer_unavailable_context'
                        : 'pod.chat_timeline.answer_closed'
                  )}
                </strong>
                {answerQuestion && <p>{answerQuestion.question}</p>}
              </div>
              <Button size="xs" variant="ghost" onClick={leaveAnswer} disabled={answering}>
                {t('pod.chat_timeline.leave_answer')}
              </Button>
            </div>
          )}
          {quoted && (
            <div className="pod-chat-quoted">
              <blockquote>{quoted.quote}</blockquote>
              <Button
                size="icon-xs"
                variant="ghost"
                aria-label={t('common.close')}
                onClick={() => {
                  model.links.value = model.links.value.filter(link => link !== quoted)
                }}>
                <RiCloseLine aria-hidden />
              </Button>
            </div>
          )}
          {editing && conversationID ? (
            <MessageAttachments
              conversationID={conversationID}
              messageID={editing.messageID}
              attachments={editedAttachments ?? []}
            />
          ) : (
            <ChatAttachmentDrafts model={model.attachments} disabled={disabled} />
          )}
          <div className="pod-chat-draft-pages">
            {model.links.value
              .filter(link => link.kind === 'page' && link.quote == null)
              .map(link => (
                <DraftPageChip
                  key={link.id}
                  id={link.id}
                  onRemove={name => {
                    model.links.value = model.links.value.filter(item => item !== link)
                    if (name) model.draft.value = removePageMention(model.draft.value, name)
                  }}
                />
              ))}
          </div>
          <InputGroupTextarea
            ref={textarea}
            autoFocus
            disabled={answering}
            aria-label={t('pod.chat.message_label')}
            aria-autocomplete="list"
            aria-haspopup="listbox"
            aria-controls={picker ? completionID : undefined}
            className="pod-chat-composer-input"
            placeholder={t(answerID ? 'pod.chat_timeline.answer_placeholder' : 'pod.chat_room.composer_hint')}
            rows={variant === 'hero' ? 3 : 1}
            value={draft}
            onChange={event => {
              model.draft.value = event.target.value
              if (!model.editing.value) {
                model.mentions.value = model.mentions.value.filter(mention =>
                  hasDraftMention(event.target.value, mention.displayName)
                )
              }
              syncPicker(event.target)
            }}
            onSelect={event => syncPicker(event.currentTarget)}
            onCompositionStart={() => {
              composing.current = true
              updatePicker(undefined)
            }}
            onCompositionEnd={event => {
              composing.current = false
              syncPicker(event.currentTarget)
            }}
            onKeyDown={event => {
              if (composing.current || event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) return
              if (picker && completion.current?.onKeyDown(event)) return
              if (event.key === 'Escape' && model.editing.value) {
                event.preventDefault()
                model.cancelEdit()
                return
              }
              if (event.key === 'Escape' && answerID) {
                event.preventDefault()
                model.cancelAnswer()
                return
              }
              if (
                event.key === 'ArrowUp' &&
                !answerID &&
                !draft &&
                textarea.current?.selectionStart === textarea.current?.selectionEnd &&
                detail
              ) {
                event.preventDefault()
                commands.recallLast()
              }
              if (
                shouldSendOnEnter({
                  key: event.key,
                  shiftKey: event.shiftKey,
                  isComposing: event.nativeEvent.isComposing,
                  keyCode: event.nativeEvent.keyCode
                })
              ) {
                event.preventDefault()
                send()
              }
            }}
          />
          <InputGroupAddon align="block-end" className="pod-chat-composer-tools">
            <div className="pod-chat-recipient-tools">
              <ChatAttachmentButton model={model.attachments} disabled={disabled || !!model.editing.value} />
              <Button
                type="button"
                size="icon-sm"
                variant="ghost"
                aria-label={t('pod.chat_room.mention')}
                onClick={() => open('mention')}>
                <RiAtLine aria-hidden />
              </Button>
              <Button
                type="button"
                size="icon-sm"
                variant="ghost"
                aria-label={t('pod.chat_room.commands')}
                onClick={() => open('slash')}>
                <RiCommandLine aria-hidden />
              </Button>
              {personalAssistant && !conversationID ? (
                <span className="px-2 text-xs text-fg-secondary">{t('pod.chat.personal_assistant')}</span>
              ) : (
                <Select
                  key={roomAgents.map(agent => agent.uid).join(':')}
                  value={recipientUID}
                  onValueChange={value => {
                    if (value == null) return
                    if (conversationID) model.targetAgentUID.value = value === '__listeners__' ? '' : value
                    else {
                      model.selectedAgentUID.value = value
                      model.modelProfile.value = null
                    }
                  }}
                  disabled={!agentsLoaded || sending || answering || !!answerID || !!model.editing.value}>
                  <SelectTrigger
                    ref={recipientControl}
                    size="sm"
                    variant="ghost"
                    className="pod-chat-agent-picker"
                    aria-label={t('pod.chat.choose_agent')}>
                    <SelectValue placeholder={t('pod.chat.choose_agent')} />
                  </SelectTrigger>
                  <SelectContent>
                    {conversationID && (group || humanOnly) && (
                      <SelectItem value="__listeners__">
                        {t(roomAgents.length ? 'pod.chat_room.listeners' : 'pod.chat_room.people_only')}
                      </SelectItem>
                    )}
                    {recipientAgentUIDs.map(uid => {
                      const available = roomAgents.some(agent => agent.uid === uid)
                      const name = recipientNames.get(uid)
                      return (
                        <SelectItem key={uid} value={uid} disabled={!available}>
                          {available
                            ? name
                            : name
                              ? `${name} (${t('pod.chat_room.unavailable')})`
                              : t('pod.chat_room.unavailable')}
                        </SelectItem>
                      )
                    })}
                  </SelectContent>
                </Select>
              )}
              {modelAgentUID ? (
                <ModelControls
                  inline
                  agentUID={modelAgentUID}
                  open={modelOpen}
                  onOpenChange={setModelOpen}
                  conversationID={conversationID}
                  draftProfile={model.modelProfile.value}
                  onDraftProfileChange={profile => {
                    model.modelProfile.value = profile
                  }}
                  disabled={sending || answering || !!answerID || !!model.editing.value}
                />
              ) : (
                detail &&
                detail.conversation.agents.length > 0 && (
                  <Button type="button" variant="ghost" size="sm" onClick={onSummary}>
                    {t('pod.chat_room.models')}
                  </Button>
                )
              )}
            </div>
            <div className="pod-chat-send-tools">
              {model.editing.value && (
                <Button type="button" size="xs" variant="ghost" onClick={() => model.cancelEdit()}>
                  {t('pod.chat.cancel_pending')}
                </Button>
              )}
              {working && commands.canStop && (
                <InputGroupButton
                  type="button"
                  size="sm"
                  variant="outline"
                  className="h-7 gap-1 px-2 [&>svg]:size-3.5"
                  aria-label={t('pod.chat.stop')}
                  title={t('pod.chat.stop_hint')}
                  disabled={disabled}
                  onClick={stop}>
                  <RiStopFill aria-hidden />
                  {t('pod.chat.stop_short')}
                </InputGroupButton>
              )}
              <InputGroupButton
                type="submit"
                size="icon-sm"
                variant="default"
                aria-label={t(
                  model.editing.value
                    ? 'pod.chat.save_pending'
                    : answerID
                      ? 'pod.chat_timeline.answer'
                      : 'pod.chat.send'
                )}
                disabled={!canSubmit || answering || (!!answerID && !answerAvailable)}>
                {commands.pendingQueueAction?.action === 'edit' ||
                commands.pendingQueueAction?.action === 'edit_last' ? (
                  <RiLoader4Line className="animate-spin" aria-hidden />
                ) : model.editing.value ? (
                  <RiCheckLine aria-hidden />
                ) : (
                  <RiArrowUpLine aria-hidden />
                )}
              </InputGroupButton>
            </div>
          </InputGroupAddon>
        </InputGroup>
      </form>
    </div>
  )
}

export function removePageMention(text: string, name: string) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return text.replace(new RegExp(`@${escaped}(?![\\p{L}\\p{N}_])\\s?`, 'gu'), '')
}

function DraftPageChip({ id, onRemove }: { id: string; onRemove(name?: string): void }) {
  const { t } = useTranslation()
  const query = useQuery(pageQuery(id))
  const page = usePageMetadata(query.data?.page)
  return (
    <span className="pod-chat-draft-page">
      {page?.title || t('pod.chat_room.page_context')}
      <Button
        type="button"
        size="icon-xs"
        variant="ghost"
        aria-label={t('common.close')}
        onClick={() => onRemove(page?.title)}>
        <RiCloseLine aria-hidden />
      </Button>
    </span>
  )
}
