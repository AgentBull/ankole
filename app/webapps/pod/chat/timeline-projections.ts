import type { TFunction } from 'i18next'
import type { ConversationDetail, ConversationMessage } from '../api'
import type { DisplayMessage } from '../state/chat'
import type { ExecutionStep, InspectorTarget, LinkedExecution, TimelineLiveStream, TimelineMessage } from './types'

export type TimelineActions = {
  canEdit?(message: ConversationMessage): boolean
  edit?(message: ConversationMessage): void
  editDisabledReason?: string
  editDisabledReasonFor?(message: ConversationMessage): string | undefined
  regenerate?(message: ConversationMessage): void
}

type PendingQuestion = ConversationDetail['pendingInteractions'][number] & { state: 'pending' }

// A conversation can span days, so a message from before today names its day as well as its time.
const DAY_MS = 24 * 60 * 60_000

/**
 * The time a message shows. A message from the last 24 hours shows only its hour and minute: inside that window
 * a clock time names one moment, so the day adds nothing. An older message adds its day, and its year when that
 * is not the current one.
 */
export function messageTime(value: string, locale: string, now = new Date()) {
  const date = new Date(value)
  const recent = now.getTime() - date.getTime() < DAY_MS
  return new Intl.DateTimeFormat(locale, {
    ...(recent
      ? {}
      : { month: 'short', day: 'numeric', ...(date.getFullYear() === now.getFullYear() ? {} : { year: 'numeric' }) }),
    hour: '2-digit',
    minute: '2-digit'
  }).format(date)
}

/** Messages from one author within five minutes read as one block: the second drops its name and avatar. */
const CONTINUATION_MS = 5 * 60_000

export function continuesPrevious(
  previous: DisplayMessage | undefined,
  current: DisplayMessage,
  hasReplySource: boolean
) {
  if (!previous || previous.type !== 'committed' || current.type !== 'committed' || hasReplySource) return false
  const [a, b] = [previous.message, current.message]
  return (
    a.kind === 'message' &&
    b.kind === 'message' &&
    !!a.authorUID &&
    a.authorUID === b.authorUID &&
    Date.parse(b.createdAt) - Date.parse(a.createdAt) < CONTINUATION_MS
  )
}

export function resolveCommittedMessageEditState({
  message,
  actions,
  latestInput,
  viewerUID,
  activeEditTarget,
  hasInlineEditContext,
  backtrackID
}: {
  message: ConversationMessage
  actions?: TimelineActions
  latestInput?: ConversationDetail['latestInput']
  viewerUID: string
  activeEditTarget?: { kind: 'queue' | 'last'; messageID: string } | null
  hasInlineEditContext: boolean
  backtrackID?: string | null
}): {
  canEdit: boolean
  editDisabledReason?: string
  editingInline: boolean
  backtrackActive: boolean
} {
  const permitted = Boolean(
    actions?.edit &&
    (actions.canEdit
      ? actions.canEdit(message)
      : message.id === latestInput?.messageID && latestInput.authorUID === viewerUID)
  )
  const editDisabledReason = actions?.editDisabledReasonFor
    ? actions.editDisabledReasonFor(message)
    : actions?.editDisabledReason
  const editingInline = Boolean(
    hasInlineEditContext && activeEditTarget?.kind === 'last' && activeEditTarget.messageID === message.id
  )
  return {
    canEdit: permitted,
    editDisabledReason,
    editingInline,
    backtrackActive: backtrackID === message.id
  }
}

export function uncommittedStreams(messages: ConversationMessage[], streams: TimelineLiveStream[]) {
  return streams.filter(
    stream =>
      !messages.some(
        message => message.authorType === 'agent' && !!message.signalID && stream.signalIDs.includes(message.signalID)
      )
  )
}

export function timelineTurns(
  messages: Pick<ConversationMessage, 'id' | 'kind' | 'authorType' | 'text' | 'replyToMessageID' | 'richContent'>[]
) {
  const turns = new Map<string, { id: string; text: string; preview?: string }>()
  for (const message of messages) {
    if (message.kind !== 'message') continue
    if (message.authorType === 'human') turns.set(message.id, { id: message.id, text: message.text })
    else if (message.authorType === 'agent' && message.text && !message.richContent?.clarify) {
      const turn = message.replyToMessageID && turns.get(message.replyToMessageID)
      if (turn && !turn.preview) turn.preview = message.text
    }
  }
  return [...turns.values()]
}

export function interleavedReplySources(
  messages: Pick<
    ConversationMessage,
    'id' | 'kind' | 'authorType' | 'authorDisplayName' | 'text' | 'replyToMessageID'
  >[]
) {
  const humans = new Map<string, (typeof messages)[number]>()
  const sources = new Map<string, Pick<ConversationMessage, 'id' | 'authorDisplayName' | 'text'>>()
  let nearestHumanID: string | undefined
  for (const message of messages) {
    if (message.kind !== 'message') continue
    if (message.authorType === 'human') {
      humans.set(message.id, message)
      nearestHumanID = message.id
    } else if (message.authorType === 'agent' && message.replyToMessageID !== nearestHumanID) {
      const source = message.replyToMessageID && humans.get(message.replyToMessageID)
      if (source) sources.set(message.id, source)
    }
  }
  return sources
}

export function collapseExecutionChains(runs: LinkedExecution[]): LinkedExecution[] {
  const byJobID = new Map<string, LinkedExecution>()
  for (const run of runs) {
    if (run.kind === 'background_agent_job') byJobID.set(run.id, run)
  }

  const collapsed: LinkedExecution[] = []
  for (const run of runs) {
    if (run.kind === 'background_agent_job' && run.successorJobID && byJobID.has(run.successorJobID)) {
      continue
    }
    if (run.kind !== 'background_agent_job' || !run.continuedFromJobID) {
      collapsed.push(run)
      continue
    }
    const chainIDs = [run.id]
    let sourceSignalID = run.sourceSignalID
    let sourceMessageID = run.sourceMessageID
    let sourceToolCallID = run.sourceToolCallID
    let cursor: string | null | undefined = run.continuedFromJobID
    const visited = new Set<string>([run.id])
    while (cursor && !visited.has(cursor)) {
      visited.add(cursor)
      chainIDs.push(cursor)
      const prev = byJobID.get(cursor)
      if (!prev) break
      if (!sourceSignalID && prev.sourceSignalID) sourceSignalID = prev.sourceSignalID
      if (!sourceMessageID && prev.sourceMessageID) sourceMessageID = prev.sourceMessageID
      if (!sourceToolCallID && prev.sourceToolCallID) sourceToolCallID = prev.sourceToolCallID
      cursor = prev.continuedFromJobID
    }
    collapsed.push({
      ...run,
      sourceSignalID,
      sourceMessageID,
      sourceToolCallID,
      chainIDs
    })
  }
  return collapsed
}

export function filterPromotedExecutionSteps(
  steps: ExecutionStep[] | undefined,
  linkedRuns: LinkedExecution[]
): ExecutionStep[] {
  if (!steps?.length || !linkedRuns.length) return steps ?? []
  const linkedToolCallIDs = new Set(linkedRuns.map(run => run.sourceToolCallID).filter(Boolean))
  const hasJobCard = linkedRuns.some(run => run.kind === 'background_agent_job')
  const hasWorkflowCard = linkedRuns.some(run => run.kind === 'workflow')
  return steps.filter(step => {
    if (['failed', 'error'].includes(step.status)) return true
    if (linkedToolCallIDs.has(step.id)) return false
    if (hasJobCard && (step.tool === 'create_background_job' || step.tool === 'respawn_background_job')) {
      return false
    }
    if (hasWorkflowCard && step.tool === 'workflow') return false
    return true
  })
}

export function isExecutionActive(inspector: InspectorTarget | null | undefined, run: LinkedExecution): boolean {
  if (!inspector || inspector.type !== 'execution' || inspector.kind !== run.kind) return false
  return inspector.runID === run.id || Boolean(run.chainIDs?.includes(inspector.runID))
}

export function isPeerActive(inspector: InspectorTarget | null | undefined, exchangeID: string): boolean {
  return inspector?.type === 'peer' && inspector.exchangeID === exchangeID
}

export function placeLinkedExecutions(
  messages: Pick<ConversationMessage, 'id' | 'kind' | 'authorType' | 'signalID' | 'richContent'>[],
  streams: TimelineLiveStream[],
  runs: LinkedExecution[]
) {
  const messageBySignal = new Map(
    messages
      .filter(
        message => message.authorType === 'agent' && (message.kind === 'message' || message.richContent?.execution)
      )
      .map(message => [message.signalID, message.id])
  )
  const streamBySignal = new Map(streams.flatMap(stream => stream.signalIDs.map(id => [id, stream.agentUID] as const)))
  const placement = {
    messages: new Map<string, LinkedExecution[]>(),
    streams: new Map<string, LinkedExecution[]>()
  }
  for (const run of collapseExecutionChains(runs)) {
    const stream = run.sourceSignalID ? streamBySignal.get(run.sourceSignalID) : undefined
    const reply = run.sourceSignalID ? messageBySignal.get(run.sourceSignalID) : undefined
    const source =
      run.sourceMessageID &&
      messages.find(message => message.id === run.sourceMessageID && message.authorType === 'human')?.id
    const owner = stream ?? reply ?? source
    if (!owner) continue
    const destination = stream ? placement.streams : placement.messages
    destination.set(owner, [...(destination.get(owner) ?? []), run])
  }
  return placement
}

/**
 * Places each delegation on the reply of the turn that sent it. Ankole commits a delegation when the assistant's
 * tool call runs, which is before the reply that reports it, and both carry the turn's signal. The reply shows its
 * work and its text first and the delegation under them, where a linked run stands, so the timeline reads in the
 * order things happened. A delegation whose turn still streams stands in the live reply, and one whose reply is
 * not loaded keeps its own row.
 */
export function placeDelegations(
  messages: Pick<TimelineMessage, 'id' | 'kind' | 'authorType' | 'authorUID' | 'signalID' | 'richContent'>[],
  streams: Pick<TimelineLiveStream, 'agentUID' | 'signalIDs'>[]
) {
  const placement = {
    messages: new Map<string, string[]>(),
    streams: new Map<string, string[]>(),
    placed: new Set<string>()
  }
  messages.forEach((message, index) => {
    const signalID = message.signalID
    if (!message.richContent?.agent_peer_outbound || !signalID) return
    const reply = messages
      .slice(index + 1)
      .find(
        later =>
          later.signalID === signalID &&
          later.authorType === 'agent' &&
          later.authorUID === message.authorUID &&
          (later.kind === 'message' || !!later.richContent?.execution) &&
          !later.richContent?.agent_peer_outbound &&
          !later.richContent?.agent_peer_inbound
      )
    const stream = reply
      ? undefined
      : streams.find(stream => stream.agentUID === message.authorUID && stream.signalIDs.includes(signalID))
    const owner = reply?.id ?? stream?.agentUID
    if (!owner) return
    const destination = reply ? placement.messages : placement.streams
    destination.set(owner, [...(destination.get(owner) ?? []), message.id])
    placement.placed.add(message.id)
  })
  return placement
}

export function unloadedPendingQuestions(
  interactions: ConversationDetail['pendingInteractions'],
  messages: Pick<ConversationMessage, 'id'>[]
) {
  const loaded = new Set(messages.map(message => message.id))
  return interactions.filter(
    (question): question is PendingQuestion => question.state === 'pending' && !loaded.has(question.messageID)
  )
}

export function timelineEventLabel(
  message: Pick<TimelineMessage, 'richContent' | 'text'>,
  t: TFunction,
  locale: string
): string {
  const event = message.richContent?.event
  if (!event) return message.text
  const actor = event.actor_name
  switch (event.type) {
    case 'participants_added':
      return t('pod.chat_timeline.event_participants_added', {
        actor,
        targets: new Intl.ListFormat(locale, { type: 'conjunction' }).format(event.targets.map(target => target.name))
      })
    case 'participant_removed':
      if (event.targets.length === 1 && event.targets[0]!.uid === event.actor_uid) {
        return t('pod.chat_timeline.event_participant_left', { actor })
      }
      return t('pod.chat_timeline.event_participant_removed', {
        actor,
        targets: new Intl.ListFormat(locale, { type: 'conjunction' }).format(event.targets.map(target => target.name))
      })
    case 'title_renamed':
      return t('pod.chat_timeline.event_title_renamed', { actor, title: event.detail })
    case 'access_scope_changed': {
      if (event.detail !== 'participants' && event.detail !== 'anchor_page') return message.text
      return t('pod.chat_timeline.event_access_scope_changed', {
        actor,
        scope: t(`pod.chat_room.scope_${event.detail}`)
      })
    }
    default:
      return message.text
  }
}
