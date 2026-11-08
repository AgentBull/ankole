import { escapeRegExp } from '../../common/text'
import { isApplePlatform } from '../../common/platform'
import { usePageMetadata } from '../use-page-metadata'
import {
  Button,
  ButtonGroup,
  cn,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuShortcut,
  DropdownMenuTrigger,
  InputGroup,
  InputGroupAddon,
  InputGroupButton,
  InputGroupTextarea,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  toast,
  Spinner
} from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import {
  RiArrowDownSLine,
  RiArrowRightUpLine,
  RiArrowUpLine,
  RiCheckLine,
  RiCloseLine,
  RiCornerUpRightLine,
  RiListOrdered2,
  RiStopFill,
  RiAtLine,
  RiCommandLine
} from '@remixicon/react'
import { useEffect, useId, useImperativeHandle, useLayoutEffect, useRef, useState, type RefObject } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { podLocation } from '../../common/browser-context'
import type { ChatModel, FollowUpBehavior } from '../state/chat'
import { shouldSendOnEnter, hasDraftMention, queuedInputs } from '../state/chat'
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
import { ReplySuggestionGhost, useReplySuggestion } from './reply-suggestion'
import { useComposerBacktrackChord } from './use-timeline-backtrack'

type Model = InstanceType<typeof ChatModel>
export function Composer({
  model,
  agents,
  agentsLoaded,
  agentsPending = false,
  personalAssistant = false,
  assistantAvailable = false,
  directColleague = false,
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
  agentsPending?: boolean
  personalAssistant?: boolean
  assistantAvailable?: boolean
  directColleague?: boolean
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
  const { t, i18n } = useTranslation(),
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
  const lastCompositionEndAt = useRef<number | null>(null)
  const [isComposing, setIsComposing] = useState(false)
  const dismissedSlash = useRef<number | undefined>(undefined)
  const backtrackChord = useComposerBacktrackChord({ model, detail, commands })
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
  const queueEditing = model.editing.value?.kind === 'queue' ? model.editing.value : undefined
  const attachmentsDisabled = sending || answering || (disabled && (!!conversationID || !agentsPending))
  const callable = new Set(agents.map(agent => agent.uid))
  const answerID = model.answeringInteractionID.value
  const answerQuestion = detail?.pendingInteractions.find(question => question.interaction_id === answerID)
  const answerAvailable =
    !!answerQuestion &&
    answerQuestion.state === 'pending' &&
    !!answerQuestion.agentUID &&
    callable.has(answerQuestion.agentUID)
  const roomAgents = (detail?.conversation.agents ?? agents).filter(agent => agent.active && callable.has(agent.uid))
  const group = detail?.conversation.roomMode === 'group'
  const humanOnly = (group || detail?.conversation.accessScope === 'anchor_page') && roomAgents.length === 0
  const recipientUID =
    answerQuestion?.agentUID ??
    queueEditing?.agentUID ??
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
  const editingID = queueEditing?.messageID
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
  const send = (modeOverride?: FollowUpBehavior) => {
    if (sending || answering || !canSubmit || (answerID && !answerAvailable)) return
    updatePicker(undefined)
    if (queueEditing) {
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
    } else submit(modeOverride)
  }
  const shortcut = isApplePlatform() ? '⌘⇧↵' : 'Ctrl+Shift+Enter'
  const coarsePointer = typeof window !== 'undefined' && !!window.matchMedia?.('(pointer: coarse)').matches
  const hasQueuedInputs = !!detail?.pendingQueues.some(queue => queuedInputs(queue).length > 0)
  const showSendModeMenu =
    !queueEditing &&
    !answerID &&
    ((commands.targetWorking && commands.canSteerTarget) || (!commands.targetWorking && commands.targetPaused))
  const submitActive = canSubmit && !answering && (!answerID || answerAvailable)
  const unavailable = detail?.conversation.agents.filter(agent => !agent.active) ?? []
  const quoted = model.quoted.value
  const hasActiveAgent =
    !!detail &&
    Object.values(model.activities.value).some(
      activity =>
        activity.state === 'active' && detail.conversation.agents.some(agent => agent.uid === activity.agentUID)
    )
  const replySuggestion = useReplySuggestion({
    conversationID,
    detail,
    idle:
      !!conversationID &&
      !!detail &&
      !disabled &&
      !answering &&
      !answerID &&
      !model.editing.value &&
      !working &&
      !hasActiveAgent &&
      !model.pending.value &&
      !draft &&
      !isComposing &&
      !model.attachments.hasFiles.value &&
      !model.links.value.length,
    onUse: text => {
      pendingCaret.current = text.length
      model.draft.value = text
    }
  })
  const editedAttachments =
    queueEditing &&
    (detail?.pendingQueues
      .find(queue => queue.agentUID === queueEditing.agentUID)
      ?.inputs.find(input => input.messageID === queueEditing.messageID)?.attachments ??
      detail?.messages.find(message => message.id === queueEditing.messageID)?.attachments)
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
                ? queueEditing
                  ? () => commands.cancelEdit()
                  : () => recipientControl.current?.click()
                : onInvite
            }>
            {t(
              selectedTargetUnavailable
                ? queueEditing
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
          canNew={assistantAvailable}
          canRename={detail?.conversation.conversationKind !== 'colleague_dm'}
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
            pagesOnly={picker.kind === 'page' || !!queueEditing}
            allowAgents={!answerID}
            personalAssistant={personalAssistant}
            participantsOnly={directColleague || detail?.conversation.conversationKind === 'colleague_dm'}
            query={picker.query}
            id={completionID}
            input={textarea}
            handle={completion}
            onChoose={choose}
            onClose={close}
          />
        )
      )}
      {personalAssistant && model.mentions.value.some(mention => mention.type === 'agent') && (
        // A colleague mention in an assistant task is a delegation, not an invitation, so the composer says so.
        <p className="pod-chat-delegation-hint" role="note">
          <RiArrowRightUpLine aria-hidden />
          {t('pod.superagent.mention_hint', {
            colleagues: new Intl.ListFormat(i18n.language, { type: 'conjunction' }).format(
              model.mentions.value
                .filter(mention => mention.type === 'agent')
                .map(mention => recipientNames.get(mention.uid) ?? mention.displayName)
            )
          })}
        </p>
      )}
      <form
        {...chatAttachmentHandlers(
          model.attachments,
          attachmentsDisabled || !!queueEditing,
          queueEditing
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
          {queueEditing && conversationID ? (
            <MessageAttachments
              conversationID={conversationID}
              messageID={queueEditing.messageID}
              attachments={editedAttachments ?? []}
            />
          ) : (
            <ChatAttachmentDrafts model={model.attachments} disabled={attachmentsDisabled} />
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
          <div className="pod-chat-composer-editor">
            <InputGroupTextarea
              ref={textarea}
              autoFocus
              disabled={answering}
              aria-label={t('pod.chat.message_label')}
              aria-placeholder={replySuggestion?.text}
              aria-description={
                replySuggestion
                  ? `${t('pod.reply_suggestion.use', { text: replySuggestion.text })} (${t('pod.reply_suggestion.tab_hint')})`
                  : undefined
              }
              aria-autocomplete="list"
              aria-haspopup="listbox"
              aria-controls={picker ? completionID : undefined}
              className="pod-chat-composer-input"
              placeholder={
                replySuggestion
                  ? ''
                  : answerID
                    ? t('pod.chat_timeline.answer_placeholder')
                    : !queueEditing && commands.targetWorking
                      ? !commands.canSteerTarget
                        ? t('pod.chat_room.composer_queue_only_hint')
                        : commands.deliveryModes.primary === 'queue'
                          ? coarsePointer
                            ? t('pod.chat_room.composer_queue_only_hint')
                            : t('pod.chat_room.composer_queue_hint', { shortcut })
                          : coarsePointer
                            ? t('pod.chat_room.composer_steer_short_hint')
                            : t('pod.chat_room.composer_steer_hint', { shortcut })
                      : !queueEditing && !commands.targetWorking && commands.targetPaused && !coarsePointer
                        ? t('pod.chat_room.composer_paused_hint', { shortcut })
                        : t('pod.chat_room.composer_hint')
              }
              rows={variant === 'hero' ? 3 : 1}
              value={draft}
              onChange={event => {
                backtrackChord.reset()
                if (!composing.current) lastCompositionEndAt.current = null
                model.clearBacktrack()
                model.draft.value = event.target.value
                if (!queueEditing) {
                  model.mentions.value = model.mentions.value.filter(mention =>
                    hasDraftMention(event.target.value, mention.displayName)
                  )
                }
                syncPicker(event.target)
              }}
              onSelect={event => syncPicker(event.currentTarget)}
              onCompositionStart={() => {
                composing.current = true
                setIsComposing(true)
                updatePicker(undefined)
              }}
              onCompositionEnd={event => {
                composing.current = false
                lastCompositionEndAt.current = event.nativeEvent.timeStamp
                setIsComposing(false)
                syncPicker(event.currentTarget)
              }}
              onFocus={() => {
                model.clearBacktrack()
              }}
              onBlur={() => {
                if (composing.current) composing.current = false
                lastCompositionEndAt.current = null
                setIsComposing(false)
                backtrackChord.reset()
              }}
              onKeyDown={event => {
                if (composing.current || event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) return
                if (picker && completion.current?.onKeyDown(event)) return
                if (event.key !== 'Escape') backtrackChord.reset()
                const justEndedComposition =
                  lastCompositionEndAt.current !== null &&
                  Math.abs(event.nativeEvent.timeStamp - lastCompositionEndAt.current) < 50
                if (event.key === 'Escape' && justEndedComposition) {
                  event.preventDefault()
                  backtrackChord.reset()
                  return
                }
                if (
                  replySuggestion &&
                  event.key === 'Tab' &&
                  !event.shiftKey &&
                  !event.altKey &&
                  !event.ctrlKey &&
                  !event.metaKey
                ) {
                  event.preventDefault()
                  replySuggestion.accept()
                  return
                }
                if (event.key === 'Escape' && queueEditing) {
                  event.preventDefault()
                  event.stopPropagation()
                  commands.cancelEdit()
                  return
                }
                if (event.key === 'Escape' && answerID) {
                  event.preventDefault()
                  event.stopPropagation()
                  model.cancelAnswer()
                  return
                }
                if (backtrackChord.handleKeyDown(event)) {
                  return
                }
                if (
                  event.key === 'ArrowUp' &&
                  event.altKey &&
                  !event.ctrlKey &&
                  !event.metaKey &&
                  !event.shiftKey &&
                  !answerID &&
                  !queueEditing &&
                  !draft &&
                  textarea.current?.selectionStart === textarea.current?.selectionEnd &&
                  detail
                ) {
                  if (commands.takeBackLastQueued()) {
                    event.preventDefault()
                    return
                  }
                }
                if (
                  event.key === 'ArrowUp' &&
                  !event.altKey &&
                  !event.ctrlKey &&
                  !event.metaKey &&
                  !event.shiftKey &&
                  !answerID &&
                  !queueEditing &&
                  !draft &&
                  !model.attachments.hasFiles.value &&
                  !model.links.value.length &&
                  textarea.current?.selectionStart === textarea.current?.selectionEnd &&
                  detail
                ) {
                  event.preventDefault()
                  commands.recallLast()
                  return
                }
                if (
                  shouldSendOnEnter({
                    key: event.key,
                    shiftKey: event.shiftKey,
                    ctrlKey: event.ctrlKey,
                    metaKey: event.metaKey,
                    isComposing: event.nativeEvent.isComposing,
                    keyCode: event.nativeEvent.isComposing ? 229 : event.nativeEvent.keyCode
                  })
                ) {
                  event.preventDefault()
                  if (!event.ctrlKey && !event.metaKey && justEndedComposition) {
                    return
                  }
                  const alternate =
                    event.shiftKey && (event.ctrlKey || event.metaKey) ? commands.deliveryModes.alternate : undefined
                  send(alternate)
                }
              }}
            />
            <ReplySuggestionGhost suggestion={replySuggestion} />
          </div>
          <InputGroupAddon align="block-end" className="pod-chat-composer-tools">
            <div className="pod-chat-recipient-tools">
              <ChatAttachmentButton model={model.attachments} disabled={attachmentsDisabled || !!queueEditing} />
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
              {personalAssistant || directColleague || detail?.conversation.conversationKind === 'colleague_dm' ? (
                <span className="max-w-40 shrink-0 truncate px-2 text-[13px] text-fg-secondary">
                  {personalAssistant ? t('pod.chat.personal_assistant') : recipientNames.get(agentUID)}
                </span>
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
                  disabled={!agentsLoaded || sending || answering || !!answerID || !!queueEditing}>
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
                  activeSignalID={
                    model.activities.value[modelAgentUID]?.signalID ??
                    (detail?.pendingQueues.find(queue => queue.agentUID === modelAgentUID)?.workStatus.state ===
                    'running'
                      ? 'running'
                      : null)
                  }
                  disabled={sending || answering || !!answerID || !!queueEditing}
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
              {queueEditing && (
                <Button type="button" size="xs" variant="ghost" onClick={() => commands.cancelEdit()}>
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
                  title={t(hasQueuedInputs ? 'pod.chat.stop_hint' : 'pod.chat.stop')}
                  disabled={disabled}
                  onClick={stop}>
                  <RiStopFill aria-hidden />
                  {t('pod.chat.stop_short')}
                </InputGroupButton>
              )}
              {(() => {
                const submitButton = (
                  <InputGroupButton
                    type="submit"
                    size="icon-sm"
                    variant="default"
                    className={cn(showSendModeMenu && submitActive && 'border-r-primary-foreground/25')}
                    aria-label={t(
                      queueEditing ? 'pod.chat.save_pending' : answerID ? 'pod.chat_timeline.answer' : 'pod.chat.send'
                    )}
                    title={
                      !queueEditing && !answerID && commands.targetWorking
                        ? t(
                            commands.deliveryModes.primary === 'queue'
                              ? 'pod.chat.follow_up_queue'
                              : 'pod.chat.follow_up_steer'
                          )
                        : !queueEditing && !answerID && !commands.targetWorking && commands.targetPaused
                          ? t('pod.chat.send_immediately')
                          : undefined
                    }
                    disabled={!submitActive}>
                    {commands.pendingQueueAction?.action === 'edit' ? (
                      <Spinner aria-hidden />
                    ) : queueEditing ? (
                      <RiCheckLine aria-hidden />
                    ) : !answerID && commands.targetWorking && commands.deliveryModes.primary === 'queue' ? (
                      <RiListOrdered2 aria-hidden />
                    ) : (
                      <RiArrowUpLine aria-hidden />
                    )}
                  </InputGroupButton>
                )
                if (!showSendModeMenu) return submitButton
                return (
                  <ButtonGroup>
                    {submitButton}
                    <DropdownMenu>
                      <DropdownMenuTrigger
                        render={
                          <InputGroupButton
                            type="button"
                            size="icon-sm"
                            variant={submitActive ? 'default' : 'outline'}
                            className={cn(
                              'size-auto min-h-7 min-w-6 px-1',
                              submitActive && 'aria-expanded:border-primary-active aria-expanded:bg-primary-active'
                            )}
                            aria-label={t('pod.chat.send_mode')}
                            title={t('pod.chat.send_mode')}
                            disabled={disabled || answering}
                          />
                        }>
                        <RiArrowDownSLine aria-hidden />
                      </DropdownMenuTrigger>
                      <DropdownMenuContent align="end" className="w-60">
                        {commands.targetWorking ? (
                          <>
                            {commands.deliveryModes.alternate && (
                              <>
                                <DropdownMenuItem
                                  disabled={!canSubmit || answering}
                                  onClick={() => send(commands.deliveryModes.alternate)}>
                                  {commands.deliveryModes.alternate === 'steer' ? (
                                    <RiCornerUpRightLine aria-hidden />
                                  ) : (
                                    <RiListOrdered2 aria-hidden />
                                  )}
                                  {t(
                                    commands.deliveryModes.alternate === 'steer'
                                      ? 'pod.chat.follow_up_steer'
                                      : 'pod.chat.follow_up_queue'
                                  )}
                                  {!coarsePointer && <DropdownMenuShortcut>{shortcut}</DropdownMenuShortcut>}
                                </DropdownMenuItem>
                                <DropdownMenuSeparator />
                              </>
                            )}
                            <DropdownMenuGroup>
                              <DropdownMenuLabel>{t('pod.chat.follow_up_mode')}</DropdownMenuLabel>
                              <DropdownMenuRadioGroup
                                value={model.followUpBehavior.value}
                                onValueChange={value => model.setFollowUpBehavior(value as FollowUpBehavior)}>
                                <DropdownMenuRadioItem value="steer">
                                  {t('pod.chat.follow_up_steer')}
                                </DropdownMenuRadioItem>
                                <DropdownMenuRadioItem value="queue">
                                  {t('pod.chat.follow_up_queue')}
                                </DropdownMenuRadioItem>
                              </DropdownMenuRadioGroup>
                            </DropdownMenuGroup>
                          </>
                        ) : (
                          <>
                            <DropdownMenuItem disabled={!canSubmit || answering} onClick={() => send('steer')}>
                              <RiArrowUpLine aria-hidden />
                              {t('pod.chat.send_immediately')}
                              {!coarsePointer && <DropdownMenuShortcut>↵</DropdownMenuShortcut>}
                            </DropdownMenuItem>
                            <DropdownMenuItem disabled={!canSubmit || answering} onClick={() => send('queue')}>
                              <RiListOrdered2 aria-hidden />
                              {t('pod.chat.follow_up_queue')}
                              {!coarsePointer && <DropdownMenuShortcut>{shortcut}</DropdownMenuShortcut>}
                            </DropdownMenuItem>
                          </>
                        )}
                      </DropdownMenuContent>
                    </DropdownMenu>
                  </ButtonGroup>
                )
              })()}
            </div>
          </InputGroupAddon>
        </InputGroup>
      </form>
    </div>
  )
}

export function removePageMention(text: string, name: string) {
  const escaped = escapeRegExp(name)
  return text.replace(new RegExp(`@${escaped}(?![\\p{L}\\p{N}_])\\s?`, 'gu'), '')
}

export function DraftPageChip({ id, onRemove }: { id: string; onRemove(name?: string): void }) {
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
