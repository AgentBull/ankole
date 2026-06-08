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

export interface AiAgentLifecycleResult {
  deleteIntents: ExternalGatewayOutboundIntent[]
  handled: boolean
}

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

    const removedPending = await this.conversations.removePendingFollowupByProviderMessageId(
      conversation.id,
      input.providerMessageId
    )
    if (removedPending) return { handled: true, deleteIntents: [] }

    const target = await this.findTarget(conversation.id, input.providerMessageId, input.eventSource)
    if (!target) return { handled: false, deleteIntents: [] }

    const rendered = await this.conversations.renderedMessages(conversation.id)
    const targetIndex = rendered.findIndex(row => row.id === target.id)
    if (targetIndex < 0) return { handled: false, deleteIntents: [] }

    if (target.role === 'im_ambient') {
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

    await this.conversations.cancelGeneration(conversation.id, input.kind, input.eventId)
    input.registry.abort(conversation.id, input.kind)

    const suffix = rendered.slice(targetIndex)
    for (const row of suffix) {
      await markTranscriptEffect(row.id, { state: input.kind, source_event_id: input.eventId })
    }

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

export const aiAgentLifecycleRevisionService = new AiAgentLifecycleRevisionService()

async function markTranscriptEffect(messageId: string, effect: JsonObject): Promise<void> {
  await DB.update(AiAgentMessages)
    .set({
      metadata: sql`jsonb_set(${AiAgentMessages.metadata}, '{transcript_effect}', ${jsonbParam(effect)}, true)`,
      updatedAt: sql`now()`
    })
    .where(eq(AiAgentMessages.id, messageId))
}

function providerOutputTarget(metadata: JsonObject): JsonObject | undefined {
  const providerMessageId = get(metadata, 'outbound.provider_message_id')
  if (isNonEmptyString(providerMessageId)) return { targetMessageId: providerMessageId }
  const outboundKey = get(metadata, 'outbound.outbound_key')
  if (isNonEmptyString(outboundKey)) return { targetOutboundKey: outboundKey }
  return undefined
}
