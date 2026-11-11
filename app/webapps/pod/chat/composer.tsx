import { escapeRegExp } from '../../common/text'
import { isApplePlatform } from '../../common/platform'
import { usePageMetadata } from '../use-page-metadata'
import {
  Button,
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
  InputGroupActions,
  InputGroupAddon,
  InputGroupButton,
  InputGroupSend,
  InputGroupStop,
  InputGroupText,
  InputGroupTextarea,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  toast
} from '@ankole/uikit'
import {
  ArrowTurnRightRegular,
  ArrowUpRightRegular,
  CaretDownFilled,
  CheckmarkRegular,
  DismissRegular,
  MentionRegular,
  SendRegular,
  SlashForwardRegular,
  StopFilled,
  TextNumberListLtrRegular
} from '@ankole/uikit/icons'
import { useSignals } from '@preact/signals-react/runtime'
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
  ChatAttachmentDropzone,
  ChatAttachmentDrafts,
  MessageAttachments
} from '../chat-attachments'
import { ModelControls } from '../model-controls'
import { pageQuery } from '../content-api'
import { MentionPicker, type MentionChoice } from './mention-picker'
import { SlashCommandPicker, type SlashCommand } from './slash-command-picker'
import {
  completionAt,
  ComposerMenuHighlight,
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
  // A stop takes effect when the Agent reaches its next checkpoint. Until then the Stop button shows that the
  // request is on its way. It returns to rest when the work ends, or after a while if the work goes on, so the
  // person can ask again.
  const [stopping, setStopping] = useState(false)
  if (stopping && !working) setStopping(false)
  useEffect(() => {
    if (!stopping) return
    const timer = setTimeout(() => setStopping(false), 8000)
    return () => clearTimeout(timer)
  }, [stopping])
  const requestStop = () => {
    setStopping(true)
    stop()
  }
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
    } else if (command === 'stop') requestStop()
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
  const fixedRecipient =
    personalAssistant || directColleague || detail?.conversation.conversationKind === 'colleague_dm'
  // While a reply runs, the stop pill joins the end of the toolbar, and the recipient and the model control truncate
  // to make room. A composer whose content is narrower than 21.75rem cannot keep both at their minimums, a 40px
  // recipient label or a 32px recipient selector beside a 32px model control, so it leaves the model control out
  // until the reply ends. Editing a queued message adds a cancel button to that end, so the same composer also
  // leaves out the attach button, which stays disabled for as long as the edit lasts.
  const stopShown = working && commands.canStop
  const modelFit = stopShown ? '@max-[21.75rem]/composer:hidden' : undefined
  const attachFit = queueEditing ? modelFit : undefined
  const submitPending = sending || answering || commands.pendingQueueAction?.action === 'edit'
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
  const pageLinks = model.links.value.filter(link => link.kind === 'page' && link.quote == null)
  return (
    <div ref={shell} className="pod-chat-composer-shell">
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
          <ArrowUpRightRegular aria-hidden />
          {t('pod.superagent.mention_hint', {
            colleagues: new Intl.ListFormat(i18n.language, { type: 'conjunction' }).format(
              model.mentions.value
                .filter(mention => mention.type === 'agent')
                .map(mention => recipientNames.get(mention.uid) ?? mention.displayName)
            )
          })}
        </p>
      )}
      <ChatAttachmentDropzone
        model={model.attachments}
        disabled={attachmentsDisabled || !!queueEditing}
        onBlocked={
          queueEditing
            ? () =>
                toast.info(
                  t('pod.chat.attachments_disabled_while_editing', {
                    defaultValue: 'Finish or cancel editing before adding files.'
                  })
                )
            : undefined
        }
        className="pod-chat-composer"
        onSubmit={event => {
          event.preventDefault()
          send()
        }}>
        <InputGroup
          variant="composer"
          className="@container/composer"
          onClick={event => {
            const target = event.target
            if (
              target === event.currentTarget ||
              (target instanceof HTMLElement &&
                target.matches(
                  '.pod-chat-composer-editor, [data-slot="input-group-addon"], [data-slot="input-group-addon"] > div'
                ))
            ) {
              if (window.getSelection()?.isCollapsed !== false) textarea.current?.focus({ preventScroll: true })
            }
          }}>
          {/* What the draft carries besides its text sits above the text, on the 16px edge of the text area. Each
              piece keeps its own space below it, so the block gives back 8px of the text area's top inset. */}
          <div className="-mb-2 px-4 pt-3 empty:hidden">
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
                  <DismissRegular aria-hidden />
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
              <ChatAttachmentDrafts model={model.attachments} disabled={attachmentsDisabled} className="px-0" />
            )}
            {pageLinks.length > 0 && (
              <div className="pod-chat-draft-pages">
                {pageLinks.map(link => (
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
            )}
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
              rows={1}
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
          <InputGroupAddon align="block-end">
            <ChatAttachmentButton
              model={model.attachments}
              disabled={attachmentsDisabled || !!queueEditing}
              className={attachFit}
            />
            <InputGroupButton size="icon-lg" aria-label={t('pod.chat_room.mention')} onClick={() => open('mention')}>
              <MentionRegular />
            </InputGroupButton>
            <InputGroupButton size="icon-lg" aria-label={t('pod.chat_room.commands')} onClick={() => open('slash')}>
              <SlashForwardRegular />
            </InputGroupButton>
            {fixedRecipient ? (
              // The recipient that a conversation cannot change keeps its full name until a running reply's stop
              // pill needs the room, and then it truncates with the model selector down to its first character. A
              // composer narrower than 20rem, such as the one in a Page's side panel, leaves it out.
              <InputGroupText
                className={cn(
                  '@max-xs/composer:hidden',
                  stopShown ? 'group-data-[variant=composer]/input-group:min-w-10' : 'shrink-0'
                )}>
                <span className="max-w-40 truncate">
                  {personalAssistant ? t('pod.chat.personal_assistant') : recipientNames.get(agentUID)}
                </span>
              </InputGroupText>
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
                  size="toolbar"
                  variant="ghost"
                  className="max-w-50"
                  aria-label={t('pod.chat.choose_agent')}>
                  <SelectValue placeholder={t('pod.chat.choose_agent')} />
                </SelectTrigger>
                <SelectContent surface="composer" side="top" align="start" className="pod-chat-composer-menu">
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
                className={modelFit}
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
                  (detail?.pendingQueues.find(queue => queue.agentUID === modelAgentUID)?.workStatus.state === 'running'
                    ? 'running'
                    : null)
                }
                disabled={sending || answering || !!answerID || !!queueEditing}
              />
            ) : (
              detail &&
              detail.conversation.agents.length > 0 && (
                <InputGroupButton size="toolbar" className={cn('min-w-8! shrink', modelFit)} onClick={onSummary}>
                  <span className="truncate">{t('pod.chat_room.models')}</span>
                </InputGroupButton>
              )
            )}
            <InputGroupActions>
              {queueEditing && (
                <InputGroupButton size="toolbar" onClick={() => commands.cancelEdit()}>
                  {t('pod.chat.cancel_pending')}
                </InputGroupButton>
              )}
              {stopShown && (
                <InputGroupStop
                  aria-label={t('pod.chat.stop')}
                  title={t(hasQueuedInputs ? 'pod.chat.stop_hint' : 'pod.chat.stop')}
                  disabled={disabled}
                  loading={stopping}
                  onClick={requestStop}>
                  <StopFilled aria-hidden />
                </InputGroupStop>
              )}
              <InputGroupSend
                ready={submitActive}
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
                aria-busy={submitPending || undefined}
                disabled={!submitActive}>
                {queueEditing ? (
                  <CheckmarkRegular aria-hidden />
                ) : !answerID && commands.targetWorking && commands.deliveryModes.primary === 'queue' ? (
                  <TextNumberListLtrRegular aria-hidden />
                ) : (
                  <SendRegular aria-hidden />
                )}
              </InputGroupSend>
              {showSendModeMenu && (
                <DropdownMenu>
                  <DropdownMenuTrigger
                    render={
                      <InputGroupButton
                        size="toolbar"
                        aria-label={t('pod.chat.send_mode')}
                        title={t('pod.chat.send_mode')}
                        disabled={disabled || answering}
                      />
                    }>
                    <CaretDownFilled />
                  </DropdownMenuTrigger>
                  <DropdownMenuContent
                    surface="composer"
                    side="top"
                    align="end"
                    className="pod-chat-composer-menu w-60">
                    <ComposerMenuHighlight />
                    {commands.targetWorking ? (
                      <>
                        {commands.deliveryModes.alternate && (
                          <>
                            <DropdownMenuItem
                              disabled={!canSubmit || answering}
                              onClick={() => send(commands.deliveryModes.alternate)}>
                              {commands.deliveryModes.alternate === 'steer' ? (
                                <ArrowTurnRightRegular aria-hidden />
                              ) : (
                                <TextNumberListLtrRegular aria-hidden />
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
                            <DropdownMenuRadioItem value="steer">{t('pod.chat.follow_up_steer')}</DropdownMenuRadioItem>
                            <DropdownMenuRadioItem value="queue">{t('pod.chat.follow_up_queue')}</DropdownMenuRadioItem>
                          </DropdownMenuRadioGroup>
                        </DropdownMenuGroup>
                      </>
                    ) : (
                      <>
                        <DropdownMenuItem disabled={!canSubmit || answering} onClick={() => send('steer')}>
                          <SendRegular aria-hidden />
                          {t('pod.chat.send_immediately')}
                          {!coarsePointer && <DropdownMenuShortcut>↵</DropdownMenuShortcut>}
                        </DropdownMenuItem>
                        <DropdownMenuItem disabled={!canSubmit || answering} onClick={() => send('queue')}>
                          <TextNumberListLtrRegular aria-hidden />
                          {t('pod.chat.follow_up_queue')}
                          {!coarsePointer && <DropdownMenuShortcut>{shortcut}</DropdownMenuShortcut>}
                        </DropdownMenuItem>
                      </>
                    )}
                  </DropdownMenuContent>
                </DropdownMenu>
              )}
            </InputGroupActions>
          </InputGroupAddon>
        </InputGroup>
      </ChatAttachmentDropzone>
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
        <DismissRegular aria-hidden />
      </Button>
    </span>
  )
}
