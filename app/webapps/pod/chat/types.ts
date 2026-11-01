import type { ConversationDetail, ConversationMessage, PodActivity } from '../api'

export type ExecutionStep = {
  id: string
  tool: string
  title: string
  status: string
  duration_ms?: number
  input?: unknown
  output?: unknown
}

type LinkedRun = ConversationDetail['linkedRuns'][number]

export type LinkedExecution = LinkedRun & { agentName?: string }

export type ExecutionSummary = {
  duration_ms?: number
  thinking_summary?: string
  steps?: ExecutionStep[]
  status?: string
  model?: string
}

export type ClarifyPrompt = Pick<
  ConversationDetail['pendingInteractions'][number],
  'tool_call_id' | 'interaction_id' | 'question' | 'choices' | 'allow_free_text'
> &
  ChatInteraction

export type ChatInteraction = {
  state: 'pending' | 'answered' | 'superseded'
  choice_id?: string | null
  answer_text?: string | null
  answered_by_name?: string | null
  answered_by_uid?: string | null
}

export type ActionCardState = {
  card_id: string
  interaction_id?: string
  action_kind:
    | 'pod.page.set_sharing'
    | 'pod.page.delete'
    | 'pod.page.restore'
    | 'pod.base.delete_table'
    | 'conversation.add_participants'
    | (string & {})
  summary: string
  target_node_id?: string | null
  payload?: Record<string, unknown> | null
  status?: 'prepared' | 'executed' | 'stale' | 'cancelled'
  resolved_by_uid?: string | null
  resolved_by_name?: string | null
  resolved_at?: string | null
  resolution_note?: string | null
}

export type TimelineMessage = Omit<ConversationMessage, 'richContent'> & {
  richContent?: {
    execution?: ExecutionSummary
    clarify?: ClarifyPrompt
    action_card?: ActionCardState
    event?: {
      type: string
      actor_uid: string
      actor_name: string
      detail: string
      targets: { uid: string; name: string; type: string }[]
    }
  } | null
}

export type TimelineLiveStream = {
  agentUID: string
  agentName?: string
  responseID: string
  signalIDs: string[]
  text: string
  thinkingSummary: string
  activity?: PodActivity
  startedAt?: string
}
