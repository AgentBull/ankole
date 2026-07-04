// Public surface for the Agent Computer core. Keep this intentionally small:
// the control plane owns transcript persistence and durable commits, while this
// package exposes the active provider/tool loop, worker turn handlers, and the
// types needed to build tools.

export { runAgentLoop } from './agent-loop'
export { runTurnHandlers, runTextTurnLoop } from './turns/text_turn_loop'
export type {
  AgentConversationContextRequester,
  AIGatewayApiKeyRequester,
  InstalledSkillReplaceRequester,
  SkillOverlayReplaceRequester,
  SkillOverlayRequester,
  TextTurnLoopOptions,
  TurnHandlerResult
} from './turns/text_turn_loop'
export * from './types'
