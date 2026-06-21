import { redis } from 'bun'
import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { generateBullXText, parseJsonWithRepair, type Message } from '@/llm'
import { and, asc, desc, eq, gt, inArray, lt, sql } from 'drizzle-orm'
import { parse as parseYaml, stringify as stringifyYaml } from 'yaml'
import { DB } from '@/common/database'
import { AiAgentConversations, AiAgentMessages, Principals, type JsonObject, type JsonValue } from '@/common/db-schema'
import { isJsonObject, stringFromPath, toJsonObject, toJsonValue } from '@/common/json'
import { logger } from '@/common/logger'
import { loadSystemTimezone } from '@/config/system'
import { createUserMessage } from './core'
import type { AiAgentRuntimeProfile } from './config'
import {
  aiAgentConversationService,
  textContent,
  textFromContent,
  type AiAgentConversationService
} from './conversation-service'
import { loadDefaultMissionTemplate, loadDefaultSoulTemplate } from './library/default-soul'
import { getMission, getSoul } from './library/service'
import { buildMessageContextMetadata, mergeMessageContextMetadata } from './message-context'
import {
  ambientRecognizerResponseSchemaForLog,
  buildAmbientRecognizerSystemPrompt,
  buildAmbientRecognizerUserPrompt,
  withAmbientRecognizerStructuredOutputOptions
} from './prompts/ambient-prompt'

interface AmbientBatch {
  agentUid: string
  bindingName?: string
  conversationId: string
  providerRoomId: string
  providerThreadId: string
}

interface AmbientRecognizerResult {
  intervene: boolean
  reason_summary?: string
}

// Wake members are conversation ids. The ZSET is shared infrastructure, so every
// member read back from Redis is shape-checked against this before it is trusted
// as a conversation id and used to touch PG.
const UUID_MEMBER_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
// Per-message cap on text handed to the recognizer prompt, so one long paste
// cannot blow up the decision-context token budget.
const MAX_CHAT_SEGMENT_TEXT = 2_000
const MAX_RECOGNIZER_CONTEXT_ROWS = 10

type AiAgentMessageRow = typeof AiAgentMessages.$inferSelect

/**
 * Batches ambient (non-addressed) room messages per conversation and wakes the
 * recognizer when a batch is due.
 *
 * The Redis ZSET is the only wake ledger: member = conversation id, score = due
 * time. Batch payload (route, thread, first-seen anchor) is re-derived from PG,
 * where the ambient message rows already live, so the ledger survives process
 * restarts without a second in-memory bookkeeping copy.
 */
export class AiAgentAmbientBatcher {
  private readonly drainingMembers = new Set<string>()
  private readonly redisKey = 'bullx-agent:ai-agent:ambient-wake'

  constructor(private readonly conversations: AiAgentConversationService = aiAgentConversationService) {}

  /**
   * Arms (or pushes back) the wake for a conversation after a new ambient message
   * lands. The due time is a debounce: it slides to `now + batchWindowMs` on every
   * fresh message so a flurry of chatter collapses into one recognizer call,
   * capped so a never-quiet room still gets looked at — see below.
   *
   * A failed ZADD is logged, not thrown: the message row is already in PG, so a
   * later `schedule` or a recovery drain re-arms the wake. Losing the timer only
   * delays the look, it never drops the batch.
   */
  async schedule(input: {
    agentUid: string
    bindingName?: string
    conversationId: string
    profile: AiAgentRuntimeProfile
    providerRoomId: string
    providerThreadId: string
  }): Promise<void> {
    const now = Date.now()
    // The hard cap anchors at the oldest unprocessed ambient message so a busy
    // room cannot push the batch window forward forever.
    const oldestPending = await this.oldestPendingAmbientRow(input.conversationId)
    const firstSeenMs = oldestPending?.createdAt.getTime() ?? now
    const dueAt = Math.min(now + input.profile.ambient.batchWindowMs, firstSeenMs + input.profile.ambient.hardCapMs)
    try {
      await redis.send('ZADD', [this.redisKey, String(dueAt), input.conversationId])
    } catch (error) {
      logger.warn(
        { error, conversationId: input.conversationId },
        'Ambient wake ZADD failed; batch will only recover via a later schedule or recovery drain'
      )
    }
  }

  /**
   * Drains every wake whose due time has passed, runs the recognizer for each,
   * and returns the conversations it decided to speak in (the caller starts a
   * generation for those).
   *
   * `drainingMembers` is an in-process guard against the same conversation being
   * worked twice when two drains overlap (the per-message timer and a recovery
   * pass can both fire). A member is removed from the ZSET before the recognizer
   * runs, so a crash mid-recognize drops that wake rather than looping on it; the
   * batch is not lost — the message rows stay in PG and a later `schedule`
   * re-arms it. When a filter is given, a batch that does not match is skipped
   * but left in the ledger for the owning agent's drain to claim.
   */
  async drainDue(
    input: AiAgentRuntimeProfile | { agentUid?: string; bindingName?: string; profile: AiAgentRuntimeProfile }
  ): Promise<Array<{ conversationId: string; providerRoomId: string; providerThreadId: string }>> {
    const profile = 'profile' in input ? input.profile : input
    const filter = 'profile' in input ? input : {}
    const now = Date.now()
    const members = await this.dueMembers(now)
    const intervened: Array<{ conversationId: string; providerRoomId: string; providerThreadId: string }> = []
    for (const member of members) {
      if (this.drainingMembers.has(member)) continue
      this.drainingMembers.add(member)
      try {
        const batch = await this.loadBatch(member)
        if (!batch) {
          // Nothing left to act on (conversation gone, or every ambient row
          // already consumed by an intervention): retire the stale wake.
          await this.removeMember(member)
          continue
        }
        // Belongs to another agent/binding — leave the wake in place so that
        // agent's own drain handles it; only `continue`, do not remove.
        if (!this.matchesFilter(batch, filter)) continue
        // Remove before recognizing: at-most-once intervention per wake. A crash
        // during recognize forfeits this look rather than risking a double reply;
        // the rows remain and a later schedule re-arms a fresh wake.
        await this.removeMember(member)
        const result = await this.recognize(batch.conversationId, profile)
        if (result?.intervene) {
          intervened.push({
            conversationId: batch.conversationId,
            providerRoomId: batch.providerRoomId,
            providerThreadId: batch.providerThreadId
          })
        }
      } finally {
        this.drainingMembers.delete(member)
      }
    }
    return intervened
  }

  /**
   * Milliseconds until the soonest pending wake, so the runtime can arm one timer
   * instead of polling. Returns `undefined` when nothing is pending (no timer
   * needed) or when Redis is unreachable. Clamped at 0 so an already-overdue wake
   * fires immediately. When a filter is given it only counts wakes for that
   * agent/binding, which costs one PG lookup to resolve each member's route.
   */
  async nextDueDelayMs(input: { agentUid?: string; bindingName?: string } = {}): Promise<number | undefined> {
    let redisEntries: unknown
    try {
      redisEntries = await redis.send('ZRANGE', [this.redisKey, '0', '-1', 'WITHSCORES'])
    } catch (error) {
      logger.warn({ error }, 'Ambient wake ZRANGE failed; next due time unknown')
      return undefined
    }
    if (!Array.isArray(redisEntries)) return undefined
    const entries = scoreEntries(redisEntries)
    if (entries.length === 0) return undefined

    let candidates = entries
    if (input.agentUid || input.bindingName) {
      const routes = await this.conversationRoutes(entries.map(([member]) => member))
      candidates = entries.filter(([member]) => {
        const route = routes.get(member)
        return route !== undefined && this.matchesFilter(route, input)
      })
    }
    if (candidates.length === 0) return undefined
    return Math.max(0, Math.min(...candidates.map(([, score]) => score)) - Date.now())
  }

  /** Re-derive the batch payload for a wake member from PG. */
  private async loadBatch(member: string): Promise<AmbientBatch | undefined> {
    if (!UUID_MEMBER_PATTERN.test(member)) return undefined
    const [conversation] = await DB.select({
      id: AiAgentConversations.id,
      agentUid: AiAgentConversations.agentUid,
      metadata: AiAgentConversations.metadata
    })
      .from(AiAgentConversations)
      .where(eq(AiAgentConversations.id, member))
      .limit(1)
    if (!conversation) return undefined

    const route = isJsonObject(conversation.metadata.route) ? conversation.metadata.route : {}
    const oldestPending = await this.oldestPendingAmbientRow(member)
    if (!oldestPending) return undefined
    const refs = isJsonObject(oldestPending.metadata.provider_refs) ? oldestPending.metadata.provider_refs : {}

    const providerRoomId = stringOrUndefined(route.provider_room_id) ?? stringOrUndefined(refs.room_id)
    const providerThreadId = stringOrUndefined(refs.thread_id) ?? providerRoomId
    if (!providerRoomId || !providerThreadId) return undefined
    return {
      agentUid: conversation.agentUid,
      bindingName: stringOrUndefined(route.binding_name),
      conversationId: conversation.id,
      providerRoomId,
      providerThreadId
    }
  }

  /** agentUid/bindingName per wake member, for filtered next-due queries. */
  private async conversationRoutes(
    members: string[]
  ): Promise<Map<string, { agentUid: string; bindingName?: string }>> {
    const ids = members.filter(member => UUID_MEMBER_PATTERN.test(member))
    const routes = new Map<string, { agentUid: string; bindingName?: string }>()
    if (ids.length === 0) return routes
    const rows = await DB.select({
      id: AiAgentConversations.id,
      agentUid: AiAgentConversations.agentUid,
      metadata: AiAgentConversations.metadata
    })
      .from(AiAgentConversations)
      .where(inArray(AiAgentConversations.id, ids))
    for (const row of rows) {
      const route = isJsonObject(row.metadata.route) ? row.metadata.route : {}
      routes.set(row.id, { agentUid: row.agentUid, bindingName: stringOrUndefined(route.binding_name) })
    }
    return routes
  }

  /**
   * Oldest ambient message not yet consumed by an intervention (hard-cap anchor +
   * thread source). The last intervention acts as a watermark: only rows newer
   * than it count as "pending", so once the agent has replied, earlier observed
   * chatter no longer pulls a batch forward.
   *
   * `transcript_effect is null` excludes rows that were retracted/superseded
   * (e.g. by a message recall) so a deleted line cannot resurrect a batch.
   */
  private async oldestPendingAmbientRow(
    conversationId: string
  ): Promise<{ createdAt: Date; metadata: JsonObject } | undefined> {
    const latestInterventionAt = await this.latestInterventionAt(conversationId)
    const [row] = await DB.select({ createdAt: AiAgentMessages.createdAt, metadata: AiAgentMessages.metadata })
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          eq(AiAgentMessages.role, 'im_ambient'),
          eq(AiAgentMessages.kind, 'normal'),
          sql`${AiAgentMessages.metadata}->'transcript_effect' is null`,
          latestInterventionAt ? gt(AiAgentMessages.createdAt, latestInterventionAt) : undefined
        )
      )
      .orderBy(asc(AiAgentMessages.createdAt), asc(AiAgentMessages.id))
      .limit(1)
    return row
  }

  /**
   * Timestamp of the agent's last ambient intervention in this conversation, the
   * watermark that bounds every "pending since last reply" query. An intervention
   * is recorded as an `introspection` row tagged `control.type =
   * ambient_intervention` (written by {@link recognize}), so the boundary is
   * durable in PG and survives restarts.
   */
  private async latestInterventionAt(conversationId: string): Promise<Date | undefined> {
    const [latestIntervention] = await DB.select({ createdAt: AiAgentMessages.createdAt })
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          eq(AiAgentMessages.role, 'im_ambient'),
          eq(AiAgentMessages.kind, 'introspection'),
          sql`${AiAgentMessages.metadata}->'control'->>'type' = 'ambient_intervention'`
        )
      )
      .orderBy(desc(AiAgentMessages.createdAt), desc(AiAgentMessages.id))
      .limit(1)
    return latestIntervention?.createdAt
  }

  private async removeMember(member: string): Promise<void> {
    try {
      await redis.send('ZREM', [this.redisKey, member])
    } catch (error) {
      logger.warn({ error, member }, 'Ambient wake ZREM failed; member may be drained again')
    }
  }

  /**
   * The intervention decision. Gathers the unanswered batch plus surrounding
   * context, asks the cheap "light" model a single yes/no ("should the agent
   * visibly reply now?"), records the call as an LLM turn for observability, and
   * — only on yes — writes the synthetic introspection message that the runtime
   * later picks up to actually generate a reply.
   *
   * The recognizer never speaks to the room itself. Its sole side effect on a
   * yes is one `im_ambient`/`introspection` row whose body is the observed
   * `<chat_segment>` and whose `think` block frames it as a runtime instruction
   * (not a human request). That row is both the next turn's trigger and the
   * intervention watermark; keeping the speak/decide split means a bad decision
   * costs one cheap call, not a posted message.
   *
   * Returns the parsed decision, or `undefined` when there is nothing pending or
   * the model call failed (failures are swallowed so one bad ambient look never
   * breaks the drain loop).
   */
  private async recognize(
    conversationId: string,
    profile: AiAgentRuntimeProfile
  ): Promise<AmbientRecognizerResult | undefined> {
    const latestInterventionAt = await this.latestInterventionAt(conversationId)

    const rows = await DB.select()
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          eq(AiAgentMessages.role, 'im_ambient'),
          eq(AiAgentMessages.kind, 'normal'),
          sql`${AiAgentMessages.metadata}->'transcript_effect' is null`,
          latestInterventionAt ? gt(AiAgentMessages.createdAt, latestInterventionAt) : undefined
        )
      )
      .orderBy(desc(AiAgentMessages.createdAt))
      .limit(12)
    if (rows.length === 0) return undefined

    // Queried newest-first to cap at the 12 most recent; reverse to chronological
    // so the prompt reads in conversation order. `oldestCurrentRow` then anchors
    // the "before this batch" context windows below.
    const currentBatch = rows.slice().reverse()
    const oldestCurrentRow = currentBatch[0]!
    const agentUid = rows[0]!.agentUid
    const [recentSceneTranscript, ambientRecall] = await Promise.all([
      this.recentSceneTranscript(conversationId, oldestCurrentRow.createdAt),
      this.ambientRecall(conversationId, oldestCurrentRow.createdAt, latestInterventionAt)
    ])
    const [timezone, displayName, agentPrompt] = await Promise.all([
      loadSystemTimezone(),
      resolveAgentDisplayName(agentUid),
      loadAmbientAgentPrompt(agentUid)
    ])
    const channelContext = ambientChannelContext(currentBatch)
    const runtimeContext = rejectUndefined({
      channel: channelContext,
      conversation_id: conversationId,
      timezone
    })
    const decisionInput = renderAmbientDecisionInput({
      agent: {
        display_name: displayName,
        uid: agentUid
      },
      currentBatch,
      runtimeContext,
      recentSceneTranscript,
      ambientRecall
    })

    const systemPrompt = buildAmbientRecognizerSystemPrompt({
      agentUid,
      channelLabel: channelContext ? stringFromPath(channelContext, ['label']) : undefined,
      conversationId,
      displayName,
      mission: agentPrompt.mission,
      soul: agentPrompt.soul,
      timezone
    })
    const llmMessages: Message[] = [
      {
        role: 'user',
        timestamp: Date.now(),
        content: buildAmbientRecognizerUserPrompt(decisionInput)
      }
    ]
    const responseFormat = toJsonValue(ambientRecognizerResponseSchemaForLog())
    const llmTurn = await this.conversations.startLlmTurn({
      agentUid,
      branchId: `conversation:${conversationId}:root`,
      callIndex: 0,
      conversationId,
      kind: 'ambient_recognizer',
      leaseId: genUUIDv7(),
      profile: 'light',
      provider: profile.lightModel.config.providerId,
      model: profile.lightModel.config.model,
      reasoning: profile.lightModel.config.reasoning,
      inputMessageIds: rows.map(row => row.id),
      requestContext: {
        ambient_rows: rows.length,
        ambient_recall_rows: ambientRecall.length,
        llm_message_count: llmMessages.length,
        llm_message_roles: llmMessages.map(message => message.role),
        recent_scene_rows: recentSceneTranscript.length,
        response_format: responseFormat,
        system_prompt: systemPrompt,
        tool_count: 0,
        tool_names: []
      },
      requestRefs: rows.map(row => ambientRowRef(row)),
      requestPatches: [
        {
          type: 'llm_tool_definitions',
          tools: []
        },
        {
          type: 'llm_request',
          reason: 'ambient_recognizer',
          response_format: responseFormat,
          system_prompt: systemPrompt,
          messages: toJsonValue(llmMessages)
        }
      ]
    })

    let rawText: string | undefined
    try {
      const response = await generateBullXText(
        profile.lightModel.model,
        { systemPrompt, messages: llmMessages },
        withAmbientRecognizerStructuredOutputOptions(profile.lightModel.options)
      )
      const text = response.content
        .flatMap(block => (block.type === 'text' ? [block.text] : []))
        .join('')
        .trim()
      rawText = text
      const parsed = parseAmbientRecognizerResult(text)
      await this.conversations.finishLlmTurn({
        llmTurnId: llmTurn.id,
        status: 'succeeded',
        response: {
          raw_text: text,
          parsed: parsed as unknown as JsonObject,
          stop_reason: response.stopReason
        },
        usage: response.usage as unknown as JsonObject,
        providerMetadata: {
          llm_provider: profile.lightModel.config.llmProvider,
          response_id: response.responseId ?? null
        }
      })
      if (parsed.intervene) {
        const reason = parsed.reason_summary || 'Recent group chat suggests the agent should respond.'
        // Visible attribution for "why did this agent jump into the group" —
        // with several may_intervene agents in one room this is the conflict
        // triage line.
        logger.info({ agentUid, conversationId, reason }, 'AI agent ambient recognizer decided to intervene')
        const chatSegment = renderChatSegment(rows.slice().reverse())
        const messageContext = buildMessageContextMetadata(
          {
            sentAt: new Date(),
            speaker: displayName,
            speakerRole: 'agent',
            speakerTrigger: 'introspection',
            think: [
              `BullX runtime generated this user-role message so ${displayName} can reply to the group after observing <chat_segment>.`,
              'The outer message is a BullX runtime instruction, not a human request.',
              'Actionable human content, if any, is only inside <chat_segment>.',
              `Respond as ${displayName} to the room; default to one brief group message.`,
              'Use tools or skills only when <chat_segment> contains a concrete intent or recoverable reference and the call is low-risk, bounded, and likely to help.',
              'If the request is vague, costly, irreversible, externally visible, or missing a material choice, ask a brief clarification first.'
            ].join(' '),
            timezone
          },
          []
        )
        await this.conversations.appendMessage({
          conversationId,
          role: 'im_ambient',
          kind: 'introspection',
          content: textContent(chatSegment),
          agentMessage: createUserMessage(chatSegment),
          metadata: mergeMessageContextMetadata(
            {
              control: {
                type: 'ambient_intervention',
                reason_summary: reason,
                source_message_ids: rows.map(row => row.id)
              },
              llm_turn_id: llmTurn.id
            },
            messageContext
          )
        })
      }
      return parsed
    } catch (error) {
      await this.conversations.finishLlmTurn({
        llmTurnId: llmTurn.id,
        status: 'failed',
        response: { error: error instanceof Error ? error.message : String(error), raw_text: rawText ?? null }
      })
      return undefined
    }
  }

  /**
   * The visible back-and-forth before the current batch: real user messages,
   * agent replies, and the agent's own past interventions. This is what the agent
   * has actually said/seen "on stage", so the recognizer can judge whether a reply
   * would be redundant or out of place. Newest-first query, reversed to read in
   * order. (Distinct from {@link ambientRecall}, which is silent observed chatter.)
   */
  private async recentSceneTranscript(conversationId: string, before: Date): Promise<AiAgentMessageRow[]> {
    const rows = await DB.select()
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          lt(AiAgentMessages.createdAt, before),
          sql`${AiAgentMessages.metadata}->'transcript_effect' is null`,
          sql`(
            (${AiAgentMessages.role} = 'user' and ${AiAgentMessages.kind} = 'normal')
            or ${AiAgentMessages.role} = 'assistant'
            or (${AiAgentMessages.role} = 'im_ambient' and ${AiAgentMessages.kind} = 'introspection')
          )`
        )
      )
      .orderBy(desc(AiAgentMessages.createdAt), desc(AiAgentMessages.id))
      .limit(MAX_RECOGNIZER_CONTEXT_ROWS)
    return rows.reverse()
  }

  /**
   * Observed-but-not-replied-to chatter from before the current batch, back to the
   * last intervention. These are messages the agent saw silently; surfacing them
   * lets the recognizer treat a slow-building thread as one situation instead of
   * reacting to only the latest line. Bounded both by the intervention watermark
   * and the row cap.
   */
  private async ambientRecall(
    conversationId: string,
    before: Date,
    latestInterventionAt: Date | undefined
  ): Promise<AiAgentMessageRow[]> {
    const rows = await DB.select()
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          eq(AiAgentMessages.role, 'im_ambient'),
          eq(AiAgentMessages.kind, 'normal'),
          sql`${AiAgentMessages.metadata}->'transcript_effect' is null`,
          lt(AiAgentMessages.createdAt, before),
          latestInterventionAt ? gt(AiAgentMessages.createdAt, latestInterventionAt) : undefined
        )
      )
      .orderBy(desc(AiAgentMessages.createdAt), desc(AiAgentMessages.id))
      .limit(MAX_RECOGNIZER_CONTEXT_ROWS)
    return rows.reverse()
  }

  private matchesFilter(
    batch: { agentUid: string; bindingName?: string },
    filter: { agentUid?: string; bindingName?: string }
  ): boolean {
    if (filter.agentUid && batch.agentUid && batch.agentUid !== filter.agentUid) return false
    if (filter.bindingName && batch.bindingName && batch.bindingName !== filter.bindingName) return false
    return true
  }

  private async dueMembers(now: number): Promise<string[]> {
    try {
      const redisDue = await redis.send('ZRANGEBYSCORE', [this.redisKey, '-inf', String(now)])
      return Array.isArray(redisDue) ? redisDue.map(String) : []
    } catch (error) {
      logger.warn({ error }, 'Ambient wake ZRANGEBYSCORE failed; no batches drained this pass')
      return []
    }
  }
}

function stringOrUndefined(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

export const aiAgentAmbientBatcher = new AiAgentAmbientBatcher()

function ambientRowRef(row: AiAgentMessageRow): JsonValue {
  return {
    type: 'ai_agent_message',
    id: row.id,
    role: row.role,
    kind: row.kind
  }
}

async function resolveAgentDisplayName(agentUid: string): Promise<string> {
  const [row] = await DB.select({ displayName: Principals.displayName })
    .from(Principals)
    .where(eq(Principals.uid, agentUid))
    .limit(1)
  return row?.displayName?.trim() || agentUid
}

// Loads the agent's soul/mission for the recognizer system prompt, falling back
// to the default templates when an agent has none configured so the recognizer
// always has a persona to reason from.
async function loadAmbientAgentPrompt(agentUid: string): Promise<{ mission: string; soul: string }> {
  const [soul, mission] = await Promise.all([getSoul(agentUid), getMission(agentUid)])
  return {
    soul: soul ?? (await loadDefaultSoulTemplate()),
    mission: mission ?? (await loadDefaultMissionTemplate())
  }
}

// Serializes the whole decision context to YAML for the user prompt: the explicit
// task, the agent identity, and the three message windows kept as separate keys
// (current batch vs. visible transcript vs. silent recall) so the model can tell
// what it must react to from what is only background.
function renderAmbientDecisionInput(input: {
  agent: JsonObject
  ambientRecall: AiAgentMessageRow[]
  currentBatch: AiAgentMessageRow[]
  runtimeContext: JsonObject
  recentSceneTranscript: AiAgentMessageRow[]
}): string {
  return stringifyYaml(
    {
      decision_task: 'decide_if_agent_should_visibly_reply_now',
      agent: input.agent,
      runtime_context: input.runtimeContext,
      current_observed_messages: input.currentBatch.map(row => promptRecord(row, 'observed_human')),
      recent_visible_transcript: input.recentSceneTranscript.map(row => promptRecord(row)),
      earlier_observed_messages_since_last_reply: input.ambientRecall.map(row => promptRecord(row, 'observed_human'))
    },
    { lineWidth: 0 }
  ).trim()
}

// Builds the `<chat_segment>` block embedded in the intervention message — the
// observed conversation the agent is asked to reply to. Rows with no text are
// dropped so empty/attachment-only lines do not clutter the segment.
function renderChatSegment(rows: AiAgentMessageRow[]): string {
  const payload = {
    messages: rows.flatMap(row => {
      const text = messageText(row)
      if (!text) return []
      return [
        {
          sent_at: chatMessageSentAt(row),
          speaker: chatMessageSpeaker(row),
          text
        }
      ]
    })
  }
  return ['<chat_segment format="yaml">', stringifyYaml(payload, { lineWidth: 0 }).trim(), '</chat_segment>'].join('\n')
}

// Derives the room/channel descriptor for the prompt and system header. Walks the
// batch newest-first and takes the first row that actually carries room context,
// since not every ambient row records it; returns undefined when none do.
function ambientChannelContext(rows: AiAgentMessageRow[]): JsonObject | undefined {
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const context = toJsonObject(rows[index]!.metadata.message_context)
    const room = toJsonObject(context.room)
    const label = stringFromPath(room, ['label'])
    const id = stringFromPath(room, ['id'])
    const name = stringFromPath(room, ['name'])
    const isDM = typeof room.is_dm === 'boolean' ? room.is_dm : undefined
    if (!label && !id && !name && isDM === undefined) continue
    return rejectUndefined({
      id,
      is_dm: isDM,
      label,
      name
    })
  }
  return undefined
}

function promptRecord(row: AiAgentMessageRow, role?: string): JsonObject {
  return rejectUndefined({
    message_id: row.id,
    role: role ?? promptRole(row),
    kind: row.kind,
    speaker: promptSpeaker(row),
    sent_at: chatMessageSentAt(row),
    text: messageText(row)
  })
}

// Translates the internal storage role into the label the recognizer prompt uses.
// Notably an `im_ambient`/`introspection` row is a past self-intervention, shown
// to the model as `runtime`, while a plain `im_ambient` row is observed human
// chatter (`ambient_human`).
function promptRole(row: AiAgentMessageRow): string {
  if (row.role === 'assistant') return 'agent'
  if (row.role === 'tool') return 'tool'
  if (row.role === 'im_ambient' && row.kind === 'introspection') return 'runtime'
  if (row.role === 'im_ambient') return 'ambient_human'
  return 'human'
}

function promptSpeaker(row: AiAgentMessageRow): string {
  if (row.role === 'assistant') return 'agent'
  if (row.role === 'tool') return 'tool'
  if (row.role === 'im_ambient' && row.kind === 'introspection') return 'BullX runtime'
  return chatMessageSpeaker(row)
}

function messageText(row: AiAgentMessageRow): string {
  return textFromContent(row.content).trim().slice(0, MAX_CHAT_SEGMENT_TEXT)
}

function chatMessageSentAt(row: AiAgentMessageRow): string {
  const context = toJsonObject(row.metadata.message_context)
  return stringFromPath(context, ['time', 'sent_at']) ?? row.createdAt.toISOString()
}

// Resolves a human-readable speaker name from whichever metadata shape recorded
// it. The fallback chain spans both the normalized message_context and older
// adapter-specific actor fields, so historical rows still render a name rather
// than "unknown speaker".
function chatMessageSpeaker(row: AiAgentMessageRow): string {
  const context = toJsonObject(row.metadata.message_context)
  return (
    stringFromPath(context, ['actor', 'display_name']) ??
    stringFromPath(row.metadata, ['actor', 'fullName']) ??
    stringFromPath(row.metadata, ['actor', 'userName']) ??
    stringFromPath(row.metadata, ['actor', 'display_name']) ??
    'unknown speaker'
  )
}

function rejectUndefined(value: Record<string, JsonValue | undefined>): JsonObject {
  return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined)) as JsonObject
}

// Normalizes a `ZRANGE ... WITHSCORES` reply into [member, score] pairs. The two
// RESP versions disagree on shape: RESP3 returns nested [member, score] arrays,
// RESP2 returns one flat list (member, score, member, score, ...). Handles both so
// the caller does not depend on which protocol the client negotiated. Non-finite
// scores are dropped defensively.
function scoreEntries(value: unknown[]): Array<[string, number]> {
  const entries: Array<[string, number]> = []
  for (let index = 0; index < value.length; index += 1) {
    const item = value[index]
    if (Array.isArray(item)) {
      const member = item[0]
      const score = Number(item[1])
      if (member !== undefined && Number.isFinite(score)) entries.push([String(member), score])
      continue
    }

    const score = Number(value[index + 1])
    if (Number.isFinite(score)) {
      entries.push([String(item), score])
      index += 1
    }
  }
  return entries
}

/**
 * Normalizes the recognizer's raw output into the strict decision shape.
 * `intervene` defaults to false on anything not explicitly true — when in doubt,
 * the agent stays silent, which is the safe failure mode for an uninvited reply.
 */
function parseAmbientRecognizerResult(text: string): AmbientRecognizerResult {
  const parsed = parseAmbientRecognizerJson(text)
  return {
    intervene: parsed.intervene === true,
    ...(typeof parsed.reason_summary === 'string' && parsed.reason_summary.trim()
      ? { reason_summary: parsed.reason_summary.trim() }
      : {})
  }
}

/**
 * Best-effort decode of the recognizer reply. The model is asked for JSON, but a
 * cheap model under a structured-output prompt still occasionally answers in
 * fenced YAML, XML-ish tags, or a loose `intervene: true` line. Rather than fail
 * the whole ambient look on a formatting slip, this walks a recovery ladder —
 * JSON (with repair) → YAML → XML → a bare boolean scan — and only rethrows the
 * original JSON error when every rung misses. Ordered most-structured first so a
 * clean JSON reply never pays for the looser parsers.
 */
function parseAmbientRecognizerJson(text: string): Partial<AmbientRecognizerResult> {
  try {
    return parseJsonWithRepair<Partial<AmbientRecognizerResult>>(extractJsonObjectText(text))
  } catch (error) {
    const yamlRecovered = recoverAmbientRecognizerYaml(text)
    if (yamlRecovered !== undefined) return yamlRecovered
    const xmlRecovered = recoverAmbientRecognizerXml(text)
    if (xmlRecovered !== undefined) return xmlRecovered
    const recovered = recoverAmbientRecognizerBoolean(text)
    if (recovered !== undefined) {
      return {
        intervene: recovered,
        reason_summary: recoverAmbientRecognizerReason(text)
      }
    }
    // Every rung missed: surface the JSON failure, the most informative one.
    throw error
  }
}

// Reads a fenced YAML reply. Accepts the decision either nested under a known
// wrapper key (the prompt's example shape) or at the top level, and tolerates the
// several field-name spellings the model drifts between (intervene /
// should_intervene / decision). Returns undefined to fall through to the next rung.
function recoverAmbientRecognizerYaml(text: string): Partial<AmbientRecognizerResult> | undefined {
  let parsed: unknown
  try {
    parsed = parseYaml(extractFencedBlockText(text))
  } catch {
    return undefined
  }
  if (!isJsonObject(parsed)) return undefined
  const decision = isJsonObject(parsed.im_intervention_decision)
    ? parsed.im_intervention_decision
    : isJsonObject(parsed.ambient_intervention_decision)
      ? parsed.ambient_intervention_decision
      : parsed
  const intervene = booleanDecisionValue(
    decision.intervene ?? decision.should_intervene ?? decision.shouldIntervene ?? decision.decision
  )
  if (intervene === undefined) return undefined
  const reason = stringDecisionValue(
    decision.reason_summary ?? decision.reasonSummary ?? decision.reason ?? decision.reasoning
  )
  return {
    intervene,
    ...(reason ? { reason_summary: reason } : {})
  }
}

// Reads an XML-ish reply (e.g. `<decision>intervene</decision>`). Pulls the first
// recognized decision/reason tag and maps its text to a boolean via the same
// phrase table as the other rungs. Returns undefined when the block has no tag
// pair at all, so plain prose falls through to the boolean scan.
function recoverAmbientRecognizerXml(text: string): Partial<AmbientRecognizerResult> | undefined {
  const candidate = extractFencedBlockText(text)
  if (!/<[a-z][\w:-]*\b[^>]*>[\s\S]*<\/[a-z][\w:-]*>/i.test(candidate)) return undefined
  const decisionText =
    firstXmlTagText(candidate, ['decision', 'intervene', 'should_intervene', 'shouldIntervene']) ?? ''
  const intervene = booleanDecisionValue(decisionText) ?? xmlDecisionValue(decisionText)
  if (intervene === undefined) return undefined
  const reason = stringDecisionValue(
    firstXmlTagText(candidate, ['reason_summary', 'reasonSummary', 'reason', 'reasoning'])
  )
  return {
    intervene,
    ...(reason ? { reason_summary: reason } : {})
  }
}

// Last rung: scan anywhere in the reply for an `intervene`/`should_intervene`
// assignment, even when the surrounding structure is unparseable. Deliberately
// narrow (explicit true/false only) so stray prose cannot be misread as a yes.
function recoverAmbientRecognizerBoolean(text: string): boolean | undefined {
  if (/(^|[,{;\s])["']?intervene["']?\s*[:=]\s*true\b/i.test(text)) return true
  if (/(^|[,{;\s])["']?intervene["']?\s*[:=]\s*false\b/i.test(text)) return false
  if (/(^|[,{;\s])["']?should_intervene["']?\s*[:=]\s*true\b/i.test(text)) return true
  if (/(^|[,{;\s])["']?should_intervene["']?\s*[:=]\s*false\b/i.test(text)) return false
  return undefined
}

function recoverAmbientRecognizerReason(text: string): string | undefined {
  const match = text.match(/["']?reason_summary["']?\s*[:=]\s*["']?([^{}\n\r]+?)(?:["']?\s*[,}]|$)/i)
  const reason = match?.[1]?.trim()
  if (!reason) return undefined
  return reason.length > 240 ? `${reason.slice(0, 240)}...` : reason
}

// Pulls the JSON object out of a reply that may be wrapped in a ```json fence or
// padded with prose, by slicing from the first `{` to the last `}`. Lets the
// model add chatter around the object without breaking the parse.
function extractJsonObjectText(text: string): string {
  const trimmed = text.trim()
  const fenced = trimmed.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/i)
  const candidate = fenced?.[1]?.trim() ?? trimmed
  const firstBrace = candidate.indexOf('{')
  const lastBrace = candidate.lastIndexOf('}')
  if (firstBrace >= 0 && lastBrace > firstBrace) return candidate.slice(firstBrace, lastBrace + 1)
  return candidate
}

function extractFencedBlockText(text: string): string {
  const trimmed = text.trim()
  const fenced = trimmed.match(/^```(?:[a-z0-9_-]+)?\s*([\s\S]*?)\s*```$/i)
  return fenced?.[1]?.trim() ?? trimmed
}

// Maps a decision token to a boolean. The model phrases the verdict in words as
// often as with true/false ("respond", "stay silent", "ignore"), so a fixed
// synonym table covers the common spellings; anything off-table returns undefined
// rather than guessing, keeping silence the default.
function booleanDecisionValue(value: unknown): boolean | undefined {
  if (typeof value === 'boolean') return value
  if (typeof value !== 'string') return undefined
  const normalized = value
    .trim()
    .toLowerCase()
    .replace(/[\s_-]+/g, ' ')
  if (['true', 'intervene', 'respond', 'speak', 'yes', 'should intervene'].includes(normalized)) return true
  if (
    [
      'false',
      'do not intervene',
      'dont intervene',
      "don't intervene",
      'no',
      'silent',
      'stay silent',
      'ignore',
      'no intervention'
    ].includes(normalized)
  ) {
    return false
  }
  return undefined
}

// Trims the reason text and caps it at 240 chars so a verbose model explanation
// stays a one-line attribution, not a paragraph in the logs/control metadata.
function stringDecisionValue(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined
  const text = value.trim()
  if (!text) return undefined
  return text.length > 240 ? `${text.slice(0, 240)}...` : text
}

function firstXmlTagText(text: string, tags: readonly string[]): string | undefined {
  for (const tag of tags) {
    const match = text.match(new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)</${tag}>`, 'i'))
    const value = match?.[1]?.replace(/<[^>]+>/g, ' ').trim()
    if (value) return decodeXmlText(value)
  }
  return undefined
}

function xmlDecisionValue(value: string): boolean | undefined {
  const normalized = value
    .trim()
    .toLowerCase()
    .replace(/[\s_-]+/g, ' ')
  if (['intervene', 'respond', 'speak', 'yes', 'should intervene'].includes(normalized)) return true
  if (
    [
      'do not intervene',
      'dont intervene',
      "don't intervene",
      'no',
      'silent',
      'stay silent',
      'ignore',
      'no intervention'
    ].includes(normalized)
  ) {
    return false
  }
  return undefined
}

function decodeXmlText(value: string): string {
  return value
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&')
}
