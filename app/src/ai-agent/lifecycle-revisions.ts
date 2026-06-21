import { get, isNonEmptyString } from '@pleisto/active-support'
import { and, asc, eq, sql } from 'drizzle-orm'
import { DB, jsonbParam } from '@/common/database'
import { AiAgentMessages, type JsonObject } from '@/common/db-schema'
import type { ExternalGatewayOutboundIntent } from '@/external-gateway/outbox'
import { createUserMessage } from './core'
import {
  aiAgentConversationService,
  providerRefs,
  textContent,
  type AiAgentConversationRoute,
  type AiAgentConversationService
} from './conversation-service'
import { stringFromPath } from '@/common/json'
import type { AiAgentRunRegistry } from './run-registry'

/**
 * Outcome of a recall/delete. `handled` true means this service owned the event
 * and the caller should stop; false means it did not apply (no conversation, or
 * the row moved) and the caller falls through to its default handling.
 * `deleteIntents` are outbound retractions to push — provider messages the agent
 * already sent in reply to the recalled message, which must now be deleted too.
 */
export interface AiAgentLifecycleResult {
  deleteIntents: ExternalGatewayOutboundIntent[]
  handled: boolean
}

/**
 * Reacts to a human recalling or deleting one of their own messages in the chat.
 *
 * The shape of the reaction depends entirely on *what* was recalled and whether
 * the agent has acted on it yet:
 *  - A message still sitting in the pending-followup queue is simply dropped — it
 *    never became transcript, so nothing else has to change.
 *  - An old, already-answered message cannot be un-answered; the agent is instead
 *    told, via an introspection note, that a message it once saw is gone, so its
 *    next reasoning does not rely on vanished context.
 *  - The message currently driving the live generation is the one case that
 *    triggers a real retraction: cancel the run, hide the affected transcript
 *    suffix, and emit deletes for any reply already posted.
 *
 * Recall and delete are handled identically; `kind` only changes the wording of
 * the introspection note and the recorded effect state.
 */
export class AiAgentLifecycleRevisionService {
  constructor(private readonly conversations: AiAgentConversationService = aiAgentConversationService) {}

  async handleRecallOrDelete(input: {
    eventId: string
    eventSource: string
    kind: 'recalled' | 'deleted'
    providerMessageId: string
    providerRoomId: string
    providerThreadId: string
    registry: AiAgentRunRegistry
    route: AiAgentConversationRoute
  }): Promise<AiAgentLifecycleResult> {
    const conversation = await this.conversations.getActiveConversation(input.route)
    if (!conversation) return { handled: false, deleteIntents: [] }

    // Fast path: the recalled message is still queued behind the active run and
    // has not yet been turned into transcript. Dropping it from the pending queue
    // is the whole fix — no transcript row, no posted reply, nothing to undo.
    const removedPending = await this.conversations.removePendingFollowupByProviderMessageId(
      conversation.id,
      input.providerMessageId
    )
    if (removedPending) return { handled: true, deleteIntents: [] }

    const target = await this.findTarget(conversation.id, input.providerMessageId, input.eventSource)
    if (!target) {
      // The provider id matched no live transcript row (already compacted away,
      // superseded, or never ingested). Cannot retract anything, so just leave the
      // model a note that a message it may have seen is gone.
      const note = `A provider message (${input.providerMessageId}) was ${input.kind}, but no active transcript row matched it.`
      await this.conversations.appendMessage({
        conversationId: conversation.id,
        role: 'user',
        kind: 'introspection',
        content: textContent(note),
        agentMessage: createUserMessage(note),
        eventSource: input.eventSource,
        eventId: input.eventId,
        metadata: {
          control: {
            type: input.kind,
            target_provider_message_id: input.providerMessageId,
            provider_refs: providerRefs(input)
          }
        }
      })
      return { handled: true, deleteIntents: [] }
    }

    const rendered = await this.conversations.renderedMessages(conversation.id)
    const targetIndex = rendered.findIndex(row => row.id === target.id)
    // Found the row by provider id but it is no longer in the rendered view
    // (compacted between the two reads): defer to default handling.
    if (targetIndex < 0) return { handled: false, deleteIntents: [] }

    if (target.role === 'im_ambient') {
      // Ambient (overheard, not addressed-to-agent) messages never produce a
      // reply, so the only question is whether this one already fed the model.
      // If nothing after it has reacted to it, hide it outright; otherwise it has
      // already colored the agent's view and must instead be acknowledged.
      const alreadyInfluencedTranscript = rendered
        .slice(targetIndex + 1)
        .some(row => row.role === 'im_ambient' && row.kind === 'introspection')
      if (!alreadyInfluencedTranscript) {
        await markTranscriptEffect(target.id, { state: input.kind, source_event_id: input.eventId })
        return { handled: true, deleteIntents: [] }
      }

      const ambientIntrospection = `A previously visible ambient room message (${target.id}) was ${input.kind}.`
      await this.conversations.appendMessage({
        conversationId: conversation.id,
        role: 'im_ambient',
        kind: 'introspection',
        content: textContent(ambientIntrospection),
        agentMessage: createUserMessage(ambientIntrospection),
        eventSource: input.eventSource,
        eventId: input.eventId,
        metadata: {
          control: {
            type: input.kind,
            target_message_id: target.id,
            provider_refs: providerRefs(input)
          }
        }
      })
      return { handled: true, deleteIntents: [] }
    }

    // A recalled user message only warrants a real retraction when it is the most
    // recent thing the agent is answering. Three signals decide that:
    //  - no later normal user message exists (a newer message would already own
    //    the conversation, making this one stale history),
    //  - and either it is the live generation's current trigger, or an assistant
    //    row already names it as its trigger (the run that answered it).
    const laterAddressedUser = rendered.slice(targetIndex + 1).some(row => row.role === 'user' && row.kind === 'normal')
    const assistantForTarget = rendered.some(
      row =>
        row.role === 'assistant' && stringFromPath(row.metadata, ['generation', 'trigger_message_id']) === target.id
    )
    const isLatestTrigger =
      target.role === 'user' &&
      !laterAddressedUser &&
      (conversation.generation.trigger_message_id === target.id || assistantForTarget)

    if (!isLatestTrigger) {
      // Older user message: as with ambient, it cannot be un-answered, so leave
      // the model a note rather than retracting anything.
      const userIntrospection = `A previously visible user message (${target.id}) was ${input.kind}.`
      await this.conversations.appendMessage({
        conversationId: conversation.id,
        role: 'user',
        kind: 'introspection',
        content: textContent(userIntrospection),
        agentMessage: createUserMessage(userIntrospection),
        eventSource: input.eventSource,
        eventId: input.eventId,
        metadata: {
          control: {
            type: input.kind,
            target_message_id: target.id,
            provider_refs: providerRefs(input)
          }
        }
      })
      return { handled: true, deleteIntents: [] }
    }

    // The recalled message is the one being answered: actually retract it.
    // Cancel the lease (fences the in-flight run so its commit is discarded) and
    // abort the process-local agent so it stops streaming a now-pointless reply.
    await this.conversations.cancelGeneration(conversation.id, input.kind, input.eventId)
    input.registry.abort(conversation.id, input.kind)

    // Hide the recalled message and everything after it (its replies, any
    // follow-on turns) from all future rendered views, so the model never sees a
    // question that no longer exists or the answer it gave to it.
    const suffix = rendered.slice(targetIndex)
    for (const row of suffix) {
      await markTranscriptEffect(row.id, { state: input.kind, source_event_id: input.eventId })
    }

    // For each assistant reply in that suffix that was actually posted to the
    // provider, emit a delete intent so the visible message is removed from the
    // chat too — not just hidden from the model's context.
    const deleteIntents = suffix
      .filter(row => row.role === 'assistant')
      .flatMap(row => {
        const target = providerOutputTarget(row.metadata)
        if (!target) return []
        return [
          {
            operation: 'delete' as const,
            outboundKey: `ai-agent-lifecycle-delete:${input.eventId}:${row.id}`,
            providerRoomId: input.providerRoomId,
            providerThreadId: input.providerThreadId,
            finalPayload: target
          }
        ]
      })

    return { handled: true, deleteIntents }
  }

  /**
   * Finds the transcript row a recalled provider message maps to. Only inbound
   * human rows qualify (`user`/`im_ambient`, `normal`), and only ones not already
   * retracted (`transcript_effect is null`), so a repeated event is a no-op. The
   * `?` operator tests JSONB membership: the provider id is one of the row's
   * recorded `provider_refs.message_ids` (a single human turn can span several
   * provider message ids). Oldest match wins, to anchor the retraction at the
   * earliest affected row.
   */
  private async findTarget(conversationId: string, providerMessageId: string, eventSource: string) {
    const [row] = await DB.select()
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          eq(AiAgentMessages.eventSource, eventSource),
          sql`${AiAgentMessages.role} in ('user', 'im_ambient')`,
          eq(AiAgentMessages.kind, 'normal'),
          sql`${AiAgentMessages.metadata}->'transcript_effect' is null`,
          sql`${AiAgentMessages.metadata}->'provider_refs'->'message_ids' ? ${providerMessageId}`
        )
      )
      .orderBy(asc(AiAgentMessages.createdAt))
      .limit(1)
    return row
  }
}

/** Process-wide singleton wired to the default conversation service. */

export const aiAgentLifecycleRevisionService = new AiAgentLifecycleRevisionService()

// Stamps a `transcript_effect` onto a row's metadata, which is the tombstone the
// render/recovery predicates use to exclude it (see `renderedMessages`). The row
// itself is kept for audit; only its visibility to the model is revoked.
async function markTranscriptEffect(messageId: string, effect: JsonObject): Promise<void> {
  await DB.update(AiAgentMessages)
    .set({
      metadata: sql`jsonb_set(${AiAgentMessages.metadata}, '{transcript_effect}', ${jsonbParam(effect)}, true)`,
      updatedAt: sql`now()`
    })
    .where(eq(AiAgentMessages.id, messageId))
}

// How to address an already-sent assistant output for deletion: by its concrete
// provider message id if known, else by the outbound key the outbox can resolve.
// Returns undefined when the row was never actually delivered (nothing to undo).
function providerOutputTarget(metadata: JsonObject): JsonObject | undefined {
  const providerMessageId = get(metadata, 'outbound.provider_message_id')
  if (isNonEmptyString(providerMessageId)) return { targetMessageId: providerMessageId }
  const outboundKey = get(metadata, 'outbound.outbound_key')
  if (isNonEmptyString(outboundKey)) return { targetOutboundKey: outboundKey }
  return undefined
}
