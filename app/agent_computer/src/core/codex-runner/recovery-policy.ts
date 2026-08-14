import type { JsonObject as JSONObject } from '@agentbull/active-support'

export type CodexRecoveryFailure =
  | 'transient'
  | 'payment_required'
  | 'context_overflow'
  | 'unknown_session'
  | 'terminal'
export type CodexRecoveryStage = 'resume' | 'turn'
export type CodexCredentialPoolExhaustion = Readonly<{
  retryAt?: string
}>

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
    payment_required: input => transition('durable_retry', input.state),
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
    payment_required: input => transition('durable_retry', input.state),
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
  // JSON-RPC internal error (-32603) is the app-server reporting its own
  // process-level failure ("agent loop died unexpectedly"). A replacement
  // app-server serves the next attempt, so this must stay retryable instead
  // of terminally failing the Job and its owner-session wakeup.
  if (error.code === -32603) return 'transient'

  const info = error.codexErrorInfo
  const infoName =
    typeof info === 'string'
      ? info
      : info && typeof info === 'object' && !Array.isArray(info)
        ? Object.keys(info)[0]
        : undefined
  const message = `${stringValue(error.message) ?? ''} ${stringValue(error.additionalDetails) ?? ''}`.toLowerCase()
  if (infoName === 'contextWindowExceeded') return 'context_overflow'
  if (
    codexErrorHTTPStatus(info) === 402 ||
    infoName === 'paymentRequired' ||
    infoName === 'payment_required' ||
    /\bpayment[_ -]?required\b|(?:unexpected|http(?: response)?) status[\s:]+402\b/.test(message)
  ) {
    return 'payment_required'
  }
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

  // "failed to resolve rollout path" covers the state-mismatch family where
  // the Codex state DB names a rollout file that is gone, unreadable, or not
  // a file. The thread is unrecoverable on this Worker exactly like an
  // unknown thread, so it must reach the same replay-or-replace ladder.
  if (
    /unknown[-_ ]?(session|thread)|thread .*not found|no rollout found|failed to resolve rollout path/.test(message)
  ) {
    return 'unknown_session'
  }
  if (/context window|context length|too many tokens/.test(message)) return 'context_overflow'
  if (
    /stream (?:disconnected|closed)(?: before completion)?|response stream .*?(?:disconnected|closed)|http(?: status)?[\s:]+(?:502|503|504)\b|model at capacity|systemerror|server overloaded|temporarily unavailable|agent loop died/.test(
      message
    )
  ) {
    return 'transient'
  }
  return 'terminal'
}

/**
 * Finds the AIGateway credential-pool terminal that Codex projects through its
 * own error vocabulary.
 *
 * Every Codex provider request in this runtime targets AIGateway. A terminal
 * 429 therefore means that the control plane already tried one bounded pool
 * lap, not that this worker should start another local retry loop.
 */
export function codexCredentialPoolExhaustion(error: JSONObject): CodexCredentialPoolExhaustion | undefined {
  const message = `${stringValue(error.message) ?? ''} ${stringValue(error.additionalDetails) ?? ''}`
  const normalizedMessage = message.toLowerCase()
  const info = error.codexErrorInfo
  const infoName =
    typeof info === 'string'
      ? info
      : info && typeof info === 'object' && !Array.isArray(info)
        ? Object.keys(info)[0]
        : undefined
  const status = codexErrorHTTPStatus(info)

  if (
    status !== 429 &&
    infoName !== 'usageLimitExceeded' &&
    infoName !== 'usage_limit_exceeded' &&
    !normalizedMessage.includes('credential_pool_exhausted') &&
    !normalizedMessage.includes('credential pool exhausted') &&
    !normalizedMessage.includes('credential pool is exhausted')
  ) {
    return undefined
  }

  const retryAt = retryAtFromMessage(message)
  return retryAt ? { retryAt } : {}
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

function codexErrorHTTPStatus(info: unknown): number | undefined {
  if (!info || typeof info !== 'object' || Array.isArray(info)) return undefined
  const variant = Object.values(info)[0]
  if (!variant || typeof variant !== 'object' || Array.isArray(variant)) return undefined
  const value = variant as Record<string, unknown>
  const status = value.httpStatusCode ?? value.http_status_code
  return typeof status === 'number' && Number.isInteger(status) ? status : undefined
}

function retryAtFromMessage(message: string): string | undefined {
  const machineTimestamp =
    message.match(/retry_at(?:["'\s:=]+)(\d{4}-\d{2}-\d{2}T[0-9:.]+(?:Z|[+-]\d{2}:\d{2}))/i)?.[1] ??
    message.match(/retry at (\d{4}-\d{2}-\d{2}T[0-9:.]+(?:Z|[+-]\d{2}:\d{2}))/i)?.[1]
  if (machineTimestamp) return validISOTimestamp(machineTimestamp)

  const dated = message.match(
    /try again at ([A-Z][a-z]{2}) (\d{1,2})(?:st|nd|rd|th), (\d{4}) (\d{1,2}):(\d{2}) (AM|PM)/i
  )
  if (dated) {
    const [, monthName, dayText, yearText, hourText, minuteText, meridiem] = dated
    const month = monthIndex(monthName!)
    if (month !== undefined) {
      const date = new Date(
        Number(yearText),
        month,
        Number(dayText),
        hour24(Number(hourText), meridiem!),
        Number(minuteText),
        0,
        0
      )
      if (!Number.isNaN(date.getTime())) return date.toISOString()
    }
  }

  const sameDay = message.match(/try again at (\d{1,2}):(\d{2}) (AM|PM)/i)
  if (!sameDay) return undefined
  const now = new Date()
  const date = new Date(
    now.getFullYear(),
    now.getMonth(),
    now.getDate(),
    hour24(Number(sameDay[1]), sameDay[3]!),
    Number(sameDay[2]),
    0,
    0
  )
  if (date.getTime() < now.getTime() - 60_000) date.setDate(date.getDate() + 1)
  return date.toISOString()
}

function validISOTimestamp(value: string): string | undefined {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString()
}

function monthIndex(name: string): number | undefined {
  const index = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'].indexOf(
    name.toLowerCase()
  )
  return index >= 0 ? index : undefined
}

function hour24(hour: number, meridiem: string): number {
  const normalized = hour % 12
  return meridiem.toUpperCase() === 'PM' ? normalized + 12 : normalized
}
