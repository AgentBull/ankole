import type { AiAgentRuntimeProfile } from './config'
import { loadSystemTimezone, zonedLocalTimeToUtc, zonedParts } from '@/config/system'
import {
  aiAgentConversationService,
  type AiAgentConversationRoute,
  type AiAgentConversationService
} from './conversation-service'
import { aiAgentRunRegistry, type AiAgentRunRegistry } from './run-registry'

/**
 * Gives the agent a clean conversation each "day", where the day boundary is an
 * operator-configured local wall-clock hour (e.g. reset at 04:00 local). The
 * rationale is the same as starting a new chat every morning: bound how much
 * stale history one long-lived room accumulates, so context cost and old-topic
 * bleed do not grow without limit, without the human having to issue `/new`.
 */
export class AiAgentDailyResetService {
  constructor(
    private readonly conversations: AiAgentConversationService = aiAgentConversationService,
    private readonly registry: AiAgentRunRegistry = aiAgentRunRegistry
  ) {}

  /**
   * Returns the conversation to use for an inbound, rolling over to a fresh one
   * first if the active conversation predates today's reset boundary. Called on
   * the inbound path, so the reset happens lazily on the next message after the
   * boundary passes rather than on a timer — a room with no traffic simply rolls
   * over whenever it is next used.
   */
  async ensureFreshConversation(route: AiAgentConversationRoute, profile: AiAgentRuntimeProfile) {
    const conversation = await this.conversations.getOrCreateActiveConversation(route)
    if (!profile.dailyReset.enabled) return conversation
    const boundary = dailyResetBoundary(new Date(), await loadSystemTimezone(), profile.dailyReset.hour)
    // Created at or after the most recent boundary => already today's session.
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

/** Process-wide singleton wired to the default conversation service and run registry. */
export const aiAgentDailyResetService = new AiAgentDailyResetService()

/**
 * The most recent reset instant at or before `now`: today's `hour:minute` in the
 * given timezone, or yesterday's if that time has not arrived yet today. A
 * conversation created before this instant belongs to a past day and must roll
 * over. `hour` is the configured `"HH:MM"` local reset time.
 *
 * UTC installs take a fast path on plain UTC arithmetic; every other zone goes
 * through {@link zonedLocalTimeToUtc} so the boundary lands at the intended local
 * wall-clock time regardless of the server's own offset and of DST shifts.
 */
export function dailyResetBoundary(now: Date, timezone: string, hour: string): Date {
  const [hourText, minuteText] = hour.split(':')
  const resetHour = Number(hourText)
  const resetMinute = Number(minuteText)
  if (timezone === 'Etc/UTC' || timezone === 'UTC') {
    const boundary = new Date(
      Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), resetHour, resetMinute)
    )
    // Today's reset time is still in the future => the active boundary is yesterday's.
    if (boundary.getTime() > now.getTime()) boundary.setUTCDate(boundary.getUTCDate() - 1)
    return boundary
  }

  // Non-UTC: compute against the wall-clock parts in the target zone, then map
  // the chosen local time back to a UTC instant.
  const local = zonedParts(timezone, now)
  let boundary = zonedLocalTimeToUtc({
    timezone,
    year: local.year,
    month: local.month,
    day: local.day,
    hour: resetHour,
    minute: resetMinute
  })
  // Local time is still before today's reset => the active boundary is yesterday's reset.
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
