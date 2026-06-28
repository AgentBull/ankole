// Public surface for the Agent Computer core. Keep this intentionally small:
// the control plane owns transcript persistence and durable commits, while this
// package exposes the active provider/tool loop, worker turn handlers, and the
// types needed to build tools.

export { runAgentLoop } from './agent-loop'
export type { AgentEventSink } from './agent-loop'
export { runLlmTurnHandlers, runTextTurnLoop } from './turns/text_turn_loop'
export type {
  AgentConversationContextRequester,
  ConversationHistoryRequester,
  ConversationSummaryCommitter,
  CredentialRequester,
  SkillOverlayReplaceRequester,
  SkillOverlayRequester,
  TextTurnLoopOptions,
  TurnHandlerResult
} from './turns/text_turn_loop'
export * from './types'
