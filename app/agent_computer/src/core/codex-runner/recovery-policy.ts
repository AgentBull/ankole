import type { JsonObject as JSONObject } from '@pleisto/active-support'

export type CodexRecoveryFailure = 'transient' | 'context_overflow' | 'unknown_session' | 'terminal'
export type CodexRecoveryStage = 'resume' | 'turn'

export type CodexRecoveryState = Readonly<{
  transientRetries: number
  compactRetries: number
  newThreadRetries: number
}>

export type CodexRecoveryTransition = Readonly<{
  action: 'retry_turn' | 'compact_then_retry' | 'replace_thread' | 'durable_retry' | 'fail'
  nextState: CodexRecoveryState
  delayMs?: number
}>

type TransitionInput = Readonly<{
  stage: CodexRecoveryStage
  failure: CodexRecoveryFailure
  state: CodexRecoveryState
  canCompact?: boolean
}>

type TransitionRule = (input: TransitionInput) => CodexRecoveryTransition

export const initialCodexRecoveryState: CodexRecoveryState = Object.freeze({
  transientRetries: 0,
  compactRetries: 0,
  newThreadRetries: 0
})

const recoveryTransitions: Record<CodexRecoveryStage, Record<CodexRecoveryFailure, TransitionRule>> = {
  resume: {
    transient: input => transition('durable_retry', input.state),
    context_overflow: input => transition('fail', input.state),
    unknown_session: input =>
      boundedTransition(input.state, 'newThreadRetries', 1, 'replace_thread') ?? transition('fail', input.state),
    terminal: input => transition('fail', input.state)
  },
  turn: {
    transient: input => {
      const retry = boundedTransition(input.state, 'transientRetries', 3, 'retry_turn')
      if (!retry) return transition('durable_retry', input.state)
      return {
        ...retry,
        delayMs: Math.min(250 * 2 ** input.state.transientRetries, 1_000)
      }
    },
    context_overflow: input =>
      input.canCompact
        ? (boundedTransition(input.state, 'compactRetries', 1, 'compact_then_retry') ?? transition('fail', input.state))
        : transition('fail', input.state),
    unknown_session: input =>
      boundedTransition(input.state, 'newThreadRetries', 1, 'replace_thread') ?? transition('fail', input.state),
    terminal: input => transition('fail', input.state)
  }
}

export function transitionCodexRecovery(input: TransitionInput): CodexRecoveryTransition {
  return recoveryTransitions[input.stage][input.failure](input)
}

export function classifyCodexRecoveryFailure(error: JSONObject): CodexRecoveryFailure {
  if (error.code === -32001) return 'transient'

  const info = error.codexErrorInfo
  const infoName =
    typeof info === 'string'
      ? info
      : info && typeof info === 'object' && !Array.isArray(info)
        ? Object.keys(info)[0]
        : undefined
  if (infoName === 'contextWindowExceeded') return 'context_overflow'
  if (
    [
      'serverOverloaded',
      'internalServerError',
      'httpConnectionFailed',
      'responseStreamConnectionFailed',
      'responseStreamDisconnected',
      'responseTooManyFailedAttempts'
    ].includes(infoName ?? '')
  ) {
    return 'transient'
  }
  if (infoName && infoName !== 'other') return 'terminal'

  const message = `${stringValue(error.message) ?? ''} ${stringValue(error.additionalDetails) ?? ''}`.toLowerCase()
  if (/unknown[-_ ]?(session|thread)|thread .*not found|no rollout found/.test(message)) return 'unknown_session'
  if (/context window|context length|too many tokens/.test(message)) return 'context_overflow'
  if (
    /stream (?:disconnected|closed)(?: before completion)?|response stream .*?(?:disconnected|closed)|http(?: status)?[\s:]+(?:502|503|504)\b|model at capacity|systemerror|server overloaded|temporarily unavailable/.test(
      message
    )
  ) {
    return 'transient'
  }
  return 'terminal'
}

function boundedTransition(
  state: CodexRecoveryState,
  counter: keyof CodexRecoveryState,
  limit: number,
  action: CodexRecoveryTransition['action']
): CodexRecoveryTransition | undefined {
  if (state[counter] >= limit) return undefined
  return transition(action, { ...state, [counter]: state[counter] + 1 })
}

function transition(action: CodexRecoveryTransition['action'], nextState: CodexRecoveryState): CodexRecoveryTransition {
  return { action, nextState }
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value ? value : undefined
}
