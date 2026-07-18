import { jsonObject } from '@pleisto/active-support'
import type { JSONRPCMessage } from '../../tools/codex/app-server-client'
import { normalizeCodexThreadUsage } from '../../tools/codex/protocol'
import type { BackgroundAgentJobTurnUsage } from '../../lanes/rpc_lane'

export const maxConsecutiveModelCallsWithoutProgress = 5

export type CodexNoProgressViolation = {
  threadID?: string
  consecutiveModelCalls: number
  usage: BackgroundAgentJobTurnUsage
}

type ThreadProgressState = {
  lastTotalTokens?: number
  consecutiveModelCalls: number
}

const progressNotificationMethods = new Set([
  'turn/started',
  'item/started',
  'item/completed',
  'turn/plan/updated',
  'turn/diff/updated'
])

/**
 * Bounds model/tool repair loops that consume completed model calls without
 * producing anything the Job supervisor can observe as semantic progress.
 * Long-running tools and child agents are unaffected because model-call usage
 * does not advance while they work, and their item notifications reset the
 * per-thread streak.
 */
export class CodexNoProgressGuard {
  private readonly threads = new Map<string, ThreadProgressState>()

  constructor(private readonly maxConsecutiveModelCalls = maxConsecutiveModelCallsWithoutProgress) {}

  recordNotification(message: JSONRPCMessage, fallbackThreadID?: string): CodexNoProgressViolation | undefined {
    const params = jsonObject(message.params)
    const threadID = nonemptyString(params.threadId) ?? fallbackThreadID

    if (progressNotificationMethods.has(message.method ?? '')) {
      this.recordProgress(threadID)
      return undefined
    }
    if (message.method !== 'thread/tokenUsage/updated') return undefined

    const usage = normalizeCodexThreadUsage(params.tokenUsage)
    if (!usage) return undefined

    const key = threadID ?? 'lead'
    const state = this.threads.get(key) ?? { consecutiveModelCalls: 0 }
    const totalTokens = usage.thread_total.total_tokens
    if (state.lastTotalTokens !== undefined && totalTokens <= state.lastTotalTokens) return undefined

    state.lastTotalTokens = totalTokens
    state.consecutiveModelCalls += 1
    this.threads.set(key, state)

    if (state.consecutiveModelCalls < this.maxConsecutiveModelCalls) return undefined
    return {
      ...(threadID ? { threadID } : {}),
      consecutiveModelCalls: state.consecutiveModelCalls,
      usage
    }
  }

  recordProgress(threadID?: string): void {
    const state = this.threads.get(threadID ?? 'lead')
    if (state) state.consecutiveModelCalls = 0
  }
}

function nonemptyString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value : undefined
}
