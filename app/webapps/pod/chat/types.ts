import type { ConversationDetail, ConversationMessage, PodActivity, PodExecution } from '../api'
import type { ConversationExecutionResponses } from '../api/generated/types.gen'

export type ExecutionStep = Omit<
  NonNullable<PodExecution['steps']>[number],
  'input' | 'output' | 'duration_ms' | 'skill_name' | 'label_key' | 'label_bindings'
> & {
  toolKind?: string
  skill_name?: string | null
  duration_ms?: number | null
  input?: unknown
  output?: unknown
  label_key?: string | null
  label_bindings?: Record<string, unknown> | null
  files?: Array<{ path: string; kind: string; diff?: string | null }>
}

export type ExecutionSummary = Omit<PodExecution, 'steps'> & {
  steps?: ExecutionStep[]
}

type LinkedRun = ConversationDetail['linkedRuns'][number]

export type LinkedExecution = LinkedRun & {
  agentName?: string
  /** Job IDs in the same continuation chain represented by this card. */
  chainIDs?: string[]
}
export type ConversationExecutionDetail = ConversationExecutionResponses[200]
export type ConversationExecutionItem = ConversationExecutionDetail['items'][number]

export type InspectorTarget =
  | {
      type: 'execution'
      kind: LinkedExecution['kind']
      runID: string
      title?: string
      agentName?: string
      initialRun?: LinkedExecution
      fromSummary?: boolean
    }
  | {
      type: 'peer'
      exchangeID: string
      agentUID: string
      fromSummary?: boolean
    }

/** A token count is null when no round of the group reported it. */
export type ExecutionUsage = NonNullable<ExecutionSummary['usage']>
export type ExecutionModelUsage = ExecutionUsage['models'][number]

export type ClarifyPrompt = Pick<
  ConversationDetail['pendingInteractions'][number],
  'tool_call_id' | 'interaction_id' | 'question' | 'choices' | 'allow_free_text' | 'fields'
> &
  ChatInteraction

/** One typed field of a structured clarify form, as the control plane normalized it. */
export type ClarifyField = {
  id: string
  label: string
  help?: string
  required: boolean
  default?: unknown
} & (
  | { type: 'text'; max_length: number; multiline: boolean }
  | { type: 'number'; integer: boolean; min?: number; max?: number; unit?: string }
  | { type: 'date'; min?: string; max?: string }
  | { type: 'select'; options: { value: string; label: string }[] }
  | { type: 'multi_select'; options: { value: string; label: string }[]; min_items?: number; max_items?: number }
  | { type: 'boolean' }
)

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
    | 'brain.object.create'
    | 'pod.knowledge.save'
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
    agent_peer_outbound?: { exchange_id: string; agent_uid: string }
    agent_peer_inbound?: { exchange_id: string; agent_uid: string }
    peer_agent_uid?: string
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
