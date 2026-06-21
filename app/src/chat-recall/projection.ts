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

/**
 * Derives the recall-facing fields of a message and keeps its embedding row in
 * sync with the new content.
 *
 * Runs inside the External Gateway projection transaction (`tx`) every time a
 * message is inserted or updated, so the searchable text, search metadata, and
 * content hash are always rebuilt from the latest message state. The
 * `content_hash` folds in exactly what is searched (room/message id, both text
 * fields, send time): the worker compares against it to decide whether a vector
 * needs rebuilding, so it must change if and only if the searchable content
 * changes.
 *
 * The empty-`searchText` branch is the redaction/eligibility guard: a message
 * that has been emptied (text and all link/attachment text gone, e.g. an edit to
 * blank or a redaction) is no longer recall-eligible, so its embeddings are
 * deleted immediately rather than left to drift out of the index — that prevents
 * recall from surfacing content that is no longer there. A full message delete is
 * handled upstream by the foreign-key cascade.
 */
export async function projectChatRecallDocument(
  tx: QueryExecutor,
  message: ProjectedMessage
): Promise<ProjectedMessage> {
  const searchText = recallSearchText(message).trim()
  const metadata = recallDocumentMetadata(message)
  // Skip building metadata text for non-searchable messages: with no body text
  // there is nothing to anchor a recall hit to, so the metadata index entry would
  // be dead weight.
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

  // `update().returning()` can come back empty if the row vanished mid-transaction
  // (a concurrent delete); fall back to the passed-in message so membership
  // recording still runs against known values.
  const next = updated ?? message
  await recordRoomMembershipFromMessage(tx, next, metadata)
  return next
}

/**
 * Records that an agent has seen a given room through one of its bindings.
 *
 * This is one half of the recall authorization model: search only returns rows
 * from rooms the agent has observed (the other half being requester membership).
 * Upserts so repeated observations just refresh `observedAt`. Skips silently when
 * the room is not projected yet — there is nothing to authorize against, and the
 * row will be recorded once the room appears.
 */
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

/**
 * Infers and records human room membership from a message's author.
 *
 * The other half of the authorization model: observing an author who maps to a
 * known, active human principal is treated as evidence that person is in the room,
 * so later recall requests from that person can see the room. Only trusted
 * `platform_subject` identities of active humans qualify — bots and unmatched
 * authors are ignored. Provider is matched when known so the same external id on a
 * different platform does not cross-authorize. This is the V1 "membership from
 * observed messages" path; a full member sync can upsert the same table later.
 */
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

/**
 * Builds the human-readable text that recall searches and embeds.
 *
 * Folds in not just the message body but the readable parts of its links and
 * attachments (titles, descriptions, file names, urls) so a message can be found
 * by what it shared, not only by what was typed. An all-empty result is the signal
 * that drives the not-eligible path in {@link projectChatRecallDocument}.
 */
function recallSearchText(message: ProjectedMessage): string {
  const parts = [message.text ?? '', ...message.links.flatMap(linkText), ...message.attachments.flatMap(attachmentText)]
  return parts
    .map(part => part.trim())
    .filter(Boolean)
    .join('\n')
}

// Extracts the searchable strings from one link object, tolerating arbitrary
// JSON shape (the field is provider-defined): non-string/absent fields are
// dropped rather than coerced.
function linkText(value: JsonValue): string[] {
  if (!isPlainObject(value)) return []
  const link = value as Record<string, unknown>
  return [link.title, link.description, link.url].filter((item): item is string => typeof item === 'string')
}

// Same tolerant extraction for one attachment object.
function attachmentText(value: JsonValue): string[] {
  if (!isPlainObject(value)) return []
  const attachment = value as Record<string, unknown>
  return [attachment.name, attachment.mimeType, attachment.url].filter(
    (item): item is string => typeof item === 'string'
  )
}

/**
 * Assembles the metadata object stored on the message and reused at search time.
 *
 * Adds the boolean signals the reranker leans on (has attachments/links, mentions
 * the agent) plus author and reactions, on top of the raw provider metadata. The
 * same derived shape is recomputed in the search SQL's metadata projection, so the
 * fields here must stay in step with it.
 */
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

/**
 * Serializes the searchable metadata into the `metadata_text` BM25 column.
 *
 * Concentrates the non-prose signals (author, mentions, attachment/link details,
 * scalar metadata) into one JSON string that the n-gram metadata index tokenizes,
 * so recall can match on a file name or a person's name even when the message body
 * does not contain the query.
 */
function recallMetadataText(message: ProjectedMessage, metadata: JsonObject): string {
  return JSON.stringify({
    author: metadata.author,
    mentions: message.mentions,
    attachments: message.attachments,
    links: message.links,
    metadata: metadataForSearch(metadata)
  })
}

// Keeps only scalar metadata values for indexing. Nested objects/arrays are
// dropped because serializing them into the keyword text adds noise (structural
// JSON tokens) without reliable search value.
function metadataForSearch(metadata: JsonObject): JsonObject {
  const result: JsonObject = {}
  for (const [key, value] of Object.entries(metadata)) {
    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') result[key] = value
  }
  return result
}

// Reads the platform provider id under either naming convention (snake_case from
// the wire, camelCase from internal callers). Used to scope membership matching to
// the right platform.
function platformSubjectProvider(metadata: JsonObject): string | undefined {
  const value = metadata.platform_subject_provider ?? metadata.platformSubjectProvider
  return typeof value === 'string' && value.trim() ? value.trim() : undefined
}
