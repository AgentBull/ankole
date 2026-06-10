import type { AiAgentRuntimeProfile } from './config'
import { loadSystemTimezone, zonedLocalTimeToUtc, zonedParts } from '@/config/system'
import {
  aiAgentConversationService,
  type AiAgentConversationRoute,
  type AiAgentConversationService
} from './conversation-service'
import { aiAgentRunRegistry, type AiAgentRunRegistry } from './run-registry'

export class AiAgentDailyResetService {
  constructor(
    private readonly conversations: AiAgentConversationService = aiAgentConversationService,
    private readonly registry: AiAgentRunRegistry = aiAgentRunRegistry
  ) {}

  async ensureFreshConversation(route: AiAgentConversationRoute, profile: AiAgentRuntimeProfile) {
    const conversation = await this.conversations.getOrCreateActiveConversation(route)
    if (!profile.dailyReset.enabled) return conversation
    const boundary = dailyResetBoundary(new Date(), await loadSystemTimezone(), profile.dailyReset.hour)
    if (conversation.createdAt.getTime() >= boundary.getTime()) return conversation

    if (conversation.generation.lease_id) {
      // Stale active conversation with an in-flight run: cancel the lease (authoritative — it fences the old
      // run at commit) and best-effort abort the process-local Agent so it stops streaming before rollover.
      await this.conversations.cancelGeneration(conversation.id, 'daily_reset')
      this.registry.abort(conversation.id, 'daily_reset')
    }
    return this.conversations.rolloverConversation(route, 'daily_reset')
  }
}

export const aiAgentDailyResetService = new AiAgentDailyResetService()

export function dailyResetBoundary(now: Date, timezone: string, hour: string): Date {
  const [hourText, minuteText] = hour.split(':')
  const resetHour = Number(hourText)
  const resetMinute = Number(minuteText)
  if (timezone === 'Etc/UTC' || timezone === 'UTC') {
    const boundary = new Date(
      Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), resetHour, resetMinute)
    )
    if (boundary.getTime() > now.getTime()) boundary.setUTCDate(boundary.getUTCDate() - 1)
    return boundary
  }

  const local = zonedParts(timezone, now)
  let boundary = zonedLocalTimeToUtc({
    timezone,
    year: local.year,
    month: local.month,
    day: local.day,
    hour: resetHour,
    minute: resetMinute
  })
  if (local.hour < resetHour || (local.hour === resetHour && local.minute < resetMinute)) {
    boundary = zonedLocalTimeToUtc({
      timezone,
      year: local.year,
      month: local.month,
      day: local.day - 1,
      hour: resetHour,
      minute: resetMinute
    })
  }
  return boundary
}
