import { genericHash } from '@agentbull/bullx-native-addons'
import { isPlainObject } from '@pleisto/active-support'
import { and, eq, sql } from 'drizzle-orm'
import { DB, jsonbParam, type QueryExecutor } from '@/common/database'
import {
  ExternalAgentRoomObservations,
  ExternalMessages,
  ExternalRooms,
  ExternalRoomMemberships,
  PrincipalExternalIdentities,
  Principals,
  type JsonObject,
  type JsonValue
} from '@/common/db-schema'
import { toJsonObject } from '@/common/json'

type ProjectedMessage = typeof ExternalMessages.$inferSelect

export async function projectChatRecallDocument(
  tx: QueryExecutor,
  message: ProjectedMessage
): Promise<ProjectedMessage> {
  const searchText = recallSearchText(message).trim()
  const metadata = recallDocumentMetadata(message)
  const metadataText = searchText ? recallMetadataText(message, metadata) : ''
  const contentHash = genericHash(
    JSON.stringify({
      roomId: message.roomId,
      messageId: message.messageId,
      searchText,
      metadataText,
      sentAt: message.sentAt?.toISOString() ?? null
    })
  )

  const [updated] = await tx
    .update(ExternalMessages)
    .set({
      searchText,
      metadataText,
      contentHash
    })
    .where(and(eq(ExternalMessages.roomId, message.roomId), eq(ExternalMessages.messageId, message.messageId)))
    .returning()

  if (!searchText) {
    await tx.execute(sql`DELETE FROM chat_recall_embeddings WHERE document_id = ${message.documentId}`)
  }

  const next = updated ?? message
  await recordRoomMembershipFromMessage(tx, next, metadata)
  return next
}

export async function recordAgentRoomObservation(input: {
  agentUid: string
  bindingName: string
  roomId: string
  metadata?: JsonObject
}): Promise<void> {
  const [room] = await DB.select({ id: ExternalRooms.id })
    .from(ExternalRooms)
    .where(eq(ExternalRooms.id, input.roomId))
    .limit(1)
  if (!room) return

  await DB.insert(ExternalAgentRoomObservations)
    .values({
      agentUid: input.agentUid,
      bindingName: input.bindingName,
      roomId: input.roomId,
      metadata: jsonbParam(input.metadata ?? {})
    })
    .onConflictDoUpdate({
      target: [
        ExternalAgentRoomObservations.agentUid,
        ExternalAgentRoomObservations.bindingName,
        ExternalAgentRoomObservations.roomId
      ],
      set: {
        metadata: jsonbParam(input.metadata ?? {}),
        observedAt: sql`now()`,
        updatedAt: sql`now()`
      }
    })
}

async function recordRoomMembershipFromMessage(
  tx: QueryExecutor,
  message: ProjectedMessage,
  metadata: JsonObject
): Promise<void> {
  if (!message.authorId) return

  const provider = platformSubjectProvider(metadata)
  const rows = await tx
    .select({
      principalUid: PrincipalExternalIdentities.principalUid
    })
    .from(PrincipalExternalIdentities)
    .innerJoin(Principals, eq(Principals.uid, PrincipalExternalIdentities.principalUid))
    .where(
      and(
        eq(PrincipalExternalIdentities.kind, 'platform_subject'),
        eq(PrincipalExternalIdentities.externalId, message.authorId),
        provider ? eq(PrincipalExternalIdentities.provider, provider) : undefined,
        eq(Principals.type, 'human'),
        eq(Principals.status, 'active')
      )
    )

  for (const row of rows) {
    await tx
      .insert(ExternalRoomMemberships)
      .values({
        roomId: message.roomId,
        principalUid: row.principalUid,
        externalId: message.authorId,
        source: 'message_author',
        metadata: jsonbParam({
          provider: provider ?? null,
          messageId: message.messageId
        })
      })
      .onConflictDoUpdate({
        target: [ExternalRoomMemberships.roomId, ExternalRoomMemberships.principalUid],
        set: {
          externalId: message.authorId,
          source: 'message_author',
          metadata: jsonbParam({
            provider: provider ?? null,
            messageId: message.messageId
          }),
          observedAt: sql`now()`,
          updatedAt: sql`now()`
        }
      })
  }
}

function recallSearchText(message: ProjectedMessage): string {
  const parts = [message.text ?? '', ...message.links.flatMap(linkText), ...message.attachments.flatMap(attachmentText)]
  return parts
    .map(part => part.trim())
    .filter(Boolean)
    .join('\n')
}

function linkText(value: JsonValue): string[] {
  if (!isPlainObject(value)) return []
  const link = value as Record<string, unknown>
  return [link.title, link.description, link.url].filter((item): item is string => typeof item === 'string')
}

function attachmentText(value: JsonValue): string[] {
  if (!isPlainObject(value)) return []
  const attachment = value as Record<string, unknown>
  return [attachment.name, attachment.mimeType, attachment.url].filter(
    (item): item is string => typeof item === 'string'
  )
}

function recallDocumentMetadata(message: ProjectedMessage): JsonObject {
  const metadata = toJsonObject(message.metadata)
  return {
    ...metadata,
    author: toJsonObject(message.author),
    hasAttachments: message.attachments.length > 0,
    hasLinks: message.links.length > 0,
    mentionedAgent: message.mentions.length > 0,
    reactions: message.reactions
  }
}

function recallMetadataText(message: ProjectedMessage, metadata: JsonObject): string {
  return JSON.stringify({
    author: metadata.author,
    mentions: message.mentions,
    attachments: message.attachments,
    links: message.links,
    metadata: metadataForSearch(metadata)
  })
}

function metadataForSearch(metadata: JsonObject): JsonObject {
  const result: JsonObject = {}
  for (const [key, value] of Object.entries(metadata)) {
    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') result[key] = value
  }
  return result
}

function platformSubjectProvider(metadata: JsonObject): string | undefined {
  const value = metadata.platform_subject_provider ?? metadata.platformSubjectProvider
  return typeof value === 'string' && value.trim() ? value.trim() : undefined
}
