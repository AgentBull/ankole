// oxlint-disable no-control-regex
import { anyAscii, genUUIDv7, genericHash, isBlockedIpAddress, sniffImageMedia } from '@agentbull/bullx-native-addons'
import type { ComputerFile } from '@agentbull/bullx-computer'
import { lookup } from 'node:dns/promises'
import { isIP } from 'node:net'
import path from 'node:path'
import posix from 'node:path/posix'
import type { JsonObject } from '@/common/db-schema'
import type { Logger } from '@/common/logger'
import type { ExternalGatewayMessageInput, ExternalGatewayRoomInput } from './core/events'

export const EXTERNAL_MEDIA_TEXT_INLINE_LIMIT_BYTES = 100 * 1024

export const SUPPORTED_DOCUMENT_TYPES: Record<string, string> = {
  '.pdf': 'application/pdf',
  '.md': 'text/markdown',
  '.txt': 'text/plain',
  '.csv': 'text/csv',
  '.log': 'text/plain',
  '.json': 'application/json',
  '.xml': 'application/xml',
  '.yaml': 'application/yaml',
  '.yml': 'application/yaml',
  '.toml': 'application/toml',
  '.ini': 'text/plain',
  '.cfg': 'text/plain',
  '.zip': 'application/zip',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.ts': 'text/plain',
  '.py': 'text/plain',
  '.sh': 'text/plain'
}

export const SUPPORTED_IMAGE_DOCUMENT_TYPES: Record<string, string> = {
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.gif': 'image/gif'
}

const SUPPORTED_VIDEO_TYPES: Record<string, string> = {
  '.mp4': 'video/mp4',
  '.mov': 'video/quicktime',
  '.avi': 'video/x-msvideo',
  '.mkv': 'video/x-matroska',
  '.webm': 'video/webm'
}

const SUPPORTED_AUDIO_TYPES: Record<string, string> = {
  '.ogg': 'audio/ogg',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.m4a': 'audio/mp4',
  '.opus': 'audio/opus',
  '.flac': 'audio/flac'
}

type ExternalMediaKind = 'image' | 'video' | 'audio' | 'document'

type ExternalMediaBinding = {
  adapter: string
  name: string
}

type MaterializedAttachment = {
  attachmentIndex: number
  computerPath?: string
  contentHash?: string
  displayName: string
  error?: string
  kind?: ExternalMediaKind
  mimeType?: string
  size?: number
  status: 'saved' | 'unsupported' | 'failed'
}

export type ExternalMediaComputerWriter = {
  writeFiles(files: ComputerFile[], opts?: { cwd?: string; signal?: AbortSignal }): Promise<void>
}

export type MaterializeInboundMessageAttachmentsOptions = {
  agentUid: string
  binding: ExternalMediaBinding
  computerWriter?: () => Promise<ExternalMediaComputerWriter>
  computerRoot?: string
  logger?: Logger
  room: Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput
}

type ResolvedMedia = {
  defaultExt: string
  kind: ExternalMediaKind
  mimeType: string
}

type AttachmentWithMaterialized = NonNullable<ExternalGatewayMessageInput['attachments']>[number] & {
  materialized?: MaterializedAttachment
}

export async function materializeInboundMessageAttachments(
  message: ExternalGatewayMessageInput,
  options: MaterializeInboundMessageAttachmentsOptions
): Promise<ExternalGatewayMessageInput> {
  if (!message.attachments?.length) return message

  let computerWriterPromise: Promise<ExternalMediaComputerWriter> | undefined
  const computerWriter = options.computerWriter
    ? () => (computerWriterPromise ??= options.computerWriter!())
    : undefined
  const computerRoot = options.computerRoot ?? '/workspace/user-files'
  const attachments: AttachmentWithMaterialized[] = []
  const contextNotes: string[] = []

  for (const [index, attachment] of message.attachments.entries()) {
    const sanitizedAttachment = stripExecutableAttachmentFields(attachment) as unknown as AttachmentWithMaterialized
    const result = await materializeOneAttachment({
      attachment,
      attachmentIndex: index,
      binding: options.binding,
      computerWriter,
      computerRoot,
      message
    }).catch(error => {
      options.logger?.warn?.(
        {
          error,
          agentUid: options.agentUid,
          bindingName: options.binding.name,
          messageId: message.id,
          roomId: options.room.id,
          attachmentIndex: index
        },
        'External Gateway failed to materialize inbound attachment'
      )
      const materialized = failedAttachment(index, displayNameForAttachment(attachment), 'materialization failed')
      return { contextNote: failureContextNote(materialized), materialized }
    })

    sanitizedAttachment.materialized = result.materialized
    attachments.push(sanitizedAttachment)
    if (result.contextNote) contextNotes.push(result.contextNote)
  }

  if (contextNotes.length === 0) return { ...message, attachments }

  const originalText = typeof message.text === 'string' ? message.text.trim() : ''
  return {
    ...message,
    attachments,
    text: originalText ? `${originalText}\n\n${contextNotes.join('\n\n')}` : contextNotes.join('\n\n')
  }
}

async function materializeOneAttachment(input: {
  attachment: NonNullable<ExternalGatewayMessageInput['attachments']>[number]
  attachmentIndex: number
  binding: ExternalMediaBinding
  computerWriter?: () => Promise<ExternalMediaComputerWriter>
  computerRoot: string
  message: ExternalGatewayMessageInput
}): Promise<{ contextNote?: string; materialized: MaterializedAttachment }> {
  const displayName = displayNameForAttachment(input.attachment)
  let resolved = resolveAttachmentMedia(input.attachment)
  if (!resolved) {
    const materialized = failedAttachment(
      input.attachmentIndex,
      displayName,
      'unsupported attachment type',
      'unsupported'
    )
    return { contextNote: failureContextNote(materialized), materialized }
  }

  const data = await attachmentBytes(input.attachment)
  if (!data) {
    const materialized = failedAttachment(input.attachmentIndex, displayName, 'attachment bytes unavailable')
    return { contextNote: failureContextNote(materialized), materialized }
  }

  const sniffedImage = resolved.kind === 'image' ? sniffImageMedia(Buffer.from(data)) : undefined
  if (resolved.kind === 'image') {
    if (!sniffedImage) {
      const materialized = failedAttachment(input.attachmentIndex, displayName, 'invalid image data', 'unsupported')
      return { contextNote: failureContextNote(materialized), materialized }
    }
    resolved = { ...resolved, defaultExt: sniffedImage.defaultExt, mimeType: sniffedImage.mimeType }
  }

  const contentHash = genericHash(Buffer.from(data))
  const safeName = safeFilename(displayName, resolved.kind)
  const filename = `${resolved.kind}_${genUUIDv7()}_${safeNameWithExtension(safeName, resolved.defaultExt, {
    replaceExisting: resolved.kind === 'image' && Boolean(sniffedImage)
  })}`
  const externalRelativeDir = [
    'external-gateway',
    safePathSegment(input.binding.adapter, 'adapter'),
    safePathSegment(input.binding.name, 'binding'),
    safePathSegment(input.message.id, 'message')
  ]
  const computerPath = posix.join(
    stripTrailingSlash(input.computerRoot),
    ...externalRelativeDir.map(segment => segment.replaceAll(path.sep, '/')),
    filename
  )
  const writer = await input.computerWriter?.()
  if (!writer) {
    const materialized = failedAttachment(input.attachmentIndex, displayName, 'computer storage unavailable')
    return { contextNote: failureContextNote(materialized), materialized }
  }
  await writer.writeFiles([{ path: workspaceRelativePath(computerPath), content: Buffer.from(data), mode: 0o644 }], {
    cwd: '/workspace'
  })

  const materialized: MaterializedAttachment = {
    attachmentIndex: input.attachmentIndex,
    computerPath,
    contentHash,
    displayName,
    kind: resolved.kind,
    mimeType: resolved.mimeType,
    size: data.byteLength,
    status: 'saved'
  }

  return { contextNote: await contextNoteForSavedAttachment(materialized, data), materialized }
}

function resolveAttachmentMedia(
  attachment: NonNullable<ExternalGatewayMessageInput['attachments']>[number]
): ResolvedMedia | undefined {
  const filename = typeof attachment.name === 'string' ? attachment.name : ''
  const mimeType = typeof attachment.mimeType === 'string' ? attachment.mimeType.toLowerCase() : ''
  const ext = resolveMediaExt(filename, mimeType)

  const isImage = mimeType.startsWith('image/') || ext in SUPPORTED_IMAGE_DOCUMENT_TYPES || attachment.type === 'image'
  if (isImage) {
    const defaultExt =
      ext in SUPPORTED_IMAGE_DOCUMENT_TYPES ? ext : (extFromMime(mimeType, SUPPORTED_IMAGE_DOCUMENT_TYPES) ?? '.jpg')
    return {
      defaultExt,
      kind: 'image',
      mimeType: mimeType.startsWith('image/') ? mimeType : (SUPPORTED_IMAGE_DOCUMENT_TYPES[defaultExt] ?? 'image/jpeg')
    }
  }

  const isVideo = mimeType.startsWith('video/') || ext in SUPPORTED_VIDEO_TYPES || attachment.type === 'video'
  if (isVideo) {
    const defaultExt = ext in SUPPORTED_VIDEO_TYPES ? ext : (extFromMime(mimeType, SUPPORTED_VIDEO_TYPES) ?? '.mp4')
    return {
      defaultExt,
      kind: 'video',
      mimeType: mimeType.startsWith('video/') ? mimeType : (SUPPORTED_VIDEO_TYPES[defaultExt] ?? 'video/mp4')
    }
  }

  const isAudio = mimeType.startsWith('audio/') || ext in SUPPORTED_AUDIO_TYPES || attachment.type === 'audio'
  if (isAudio) {
    const defaultExt = ext in SUPPORTED_AUDIO_TYPES ? ext : (extFromMime(mimeType, SUPPORTED_AUDIO_TYPES) ?? '.ogg')
    return {
      defaultExt,
      kind: 'audio',
      mimeType: mimeType.startsWith('audio/') ? mimeType : (SUPPORTED_AUDIO_TYPES[defaultExt] ?? 'audio/ogg')
    }
  }

  const documentExt = ext in SUPPORTED_DOCUMENT_TYPES ? ext : extFromMime(mimeType, SUPPORTED_DOCUMENT_TYPES)
  if (!documentExt) return undefined
  return {
    defaultExt: documentExt,
    kind: 'document',
    mimeType: SUPPORTED_DOCUMENT_TYPES[documentExt] ?? mimeType
  }
}

function resolveMediaExt(filename: string, mimeType: string): string {
  const fromName = path.extname(filename.replaceAll('\\', '/')).toLowerCase()
  if (fromName) return fromName
  return (
    extFromMime(mimeType, SUPPORTED_IMAGE_DOCUMENT_TYPES) ??
    extFromMime(mimeType, SUPPORTED_VIDEO_TYPES) ??
    extFromMime(mimeType, SUPPORTED_AUDIO_TYPES) ??
    extFromMime(mimeType, SUPPORTED_DOCUMENT_TYPES) ??
    ''
  )
}

function extFromMime(mimeType: string, table: Record<string, string>): string | undefined {
  if (!mimeType) return undefined
  return Object.entries(table).find(([, value]) => value === mimeType)?.[0]
}

async function attachmentBytes(
  attachment: NonNullable<ExternalGatewayMessageInput['attachments']>[number]
): Promise<Uint8Array | undefined> {
  if (attachment.fetchData) return bytesFromUnknown(await attachment.fetchData())
  if (attachment.data !== undefined) return bytesFromUnknown(attachment.data)
  if (attachment.url) return fetchAttachmentUrl(attachment.url)
  return undefined
}

async function bytesFromUnknown(value: unknown): Promise<Uint8Array | undefined> {
  if (value instanceof Uint8Array) return value
  if (value instanceof ArrayBuffer) return new Uint8Array(value)
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
  if (value instanceof Blob) return new Uint8Array(await value.arrayBuffer())
  if (value instanceof Response) return new Uint8Array(await value.arrayBuffer())
  if (typeof value === 'string') return bytesFromString(value)
  return undefined
}

function bytesFromString(value: string): Uint8Array {
  const dataUrl = /^data:([^;,]+)?(;base64)?,(.*)$/is.exec(value)
  if (!dataUrl) return Buffer.from(value)
  const payload = dataUrl[3] ?? ''
  return dataUrl[2] ? Buffer.from(payload, 'base64') : Buffer.from(decodeURIComponent(payload))
}

async function fetchAttachmentUrl(url: string): Promise<Uint8Array | undefined> {
  const parsed = new URL(url)
  if (!['http:', 'https:'].includes(parsed.protocol)) return undefined
  if (await isBlockedHost(parsed.hostname)) return undefined

  const response = await fetch(parsed)
  if (!response.ok) return undefined
  return new Uint8Array(await response.arrayBuffer())
}

async function isBlockedHost(hostname: string): Promise<boolean> {
  const host = hostname.toLowerCase().replace(/^\[/u, '').replace(/\]$/u, '')
  if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')) return true

  if (isIP(host)) return isBlockedIpAddress(host)
  try {
    const addresses = await lookup(host, { all: true })
    return addresses.some(address => isBlockedIpAddress(address.address))
  } catch {
    return true
  }
}

async function contextNoteForSavedAttachment(materialized: MaterializedAttachment, data: Uint8Array): Promise<string> {
  const note = `[${materialized.kind} '${materialized.displayName}' saved at: ${materialized.computerPath}]`
  if (!shouldInlineTextDocument(materialized, data)) return note

  const content = new TextDecoder('utf-8', { fatal: true }).decode(data)
  return `${note}\n[Content of ${materialized.displayName}]:\n${content}`
}

function shouldInlineTextDocument(materialized: MaterializedAttachment, data: Uint8Array): boolean {
  if (materialized.kind !== 'document') return false
  if (data.byteLength > EXTERNAL_MEDIA_TEXT_INLINE_LIMIT_BYTES) return false
  const ext = path.extname(materialized.displayName).toLowerCase()
  return (
    (materialized.mimeType === 'text/plain' || materialized.mimeType === 'text/markdown') &&
    (ext === '.txt' || ext === '.md')
  )
}

function failedAttachment(
  attachmentIndex: number,
  displayName: string,
  error: string,
  status: 'unsupported' | 'failed' = 'failed'
): MaterializedAttachment {
  return {
    attachmentIndex,
    displayName,
    error,
    status
  }
}

function failureContextNote(materialized: MaterializedAttachment): string {
  return `[attachment '${materialized.displayName}' could not be saved: ${materialized.error}]`
}

function displayNameForAttachment(attachment: NonNullable<ExternalGatewayMessageInput['attachments']>[number]): string {
  return safeDisplayName(attachment.name ?? attachment.url ?? attachment.type)
}

function safeDisplayName(value: string): string {
  const base = path
    .basename(value.replaceAll('\\', '/'))
    .replace(/\0/g, '')
    .replace(/[\u0000-\u001f\u007f]/g, '')
    .trim()
    .replace(/[/:]/g, '_')
  const display = base && base !== '.' && base !== '..' ? base : 'file'
  return display
}

function safeFilename(value: string, fallback: string): string {
  const base = path
    .basename(value.replaceAll('\\', '/'))
    .replace(/\0/g, '')
    .replace(/[\u0000-\u001f\u007f]/g, '')
    .trim()
    .replace(/[/:]/g, '_')
  if (base && base !== '.' && base !== '..') return base

  const asciiFallback = anyAscii(value)
    .replace(/\0/g, '')
    .replace(/[\u0000-\u001f\u007f]/g, '')
    .replace(/[\\/:\s]+/g, '_')
    .replace(/_+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 80)
  return asciiFallback && asciiFallback !== '.' && asciiFallback !== '..' ? asciiFallback : fallback
}

function safeNameWithExtension(filename: string, ext: string, options: { replaceExisting?: boolean } = {}): string {
  const currentExt = path.extname(filename)
  if (currentExt) {
    return options.replaceExisting ? `${filename.slice(0, -currentExt.length)}${ext}` : filename
  }
  return `${filename}${ext}`
}

function safePathSegment(value: string, fallback: string): string {
  const segment = value
    .replace(/\0/g, '')
    .replace(/[^\w.-]/g, '_')
    .slice(0, 96)
  return segment && segment !== '.' && segment !== '..' ? segment : fallback
}

function stripExecutableAttachmentFields(
  attachment: NonNullable<ExternalGatewayMessageInput['attachments']>[number]
): JsonObject {
  const { data: _data, fetchData: _fetchData, ...jsonSafe } = attachment
  return jsonSafe as unknown as JsonObject
}

function stripTrailingSlash(value: string): string {
  return value.replace(/\/+$/u, '')
}

function workspaceRelativePath(computerPath: string): string {
  const normalized = posix.normalize(computerPath)
  if (normalized.startsWith('/workspace/')) return normalized.slice('/workspace/'.length)
  if (!normalized.startsWith('/')) return normalized
  throw new Error(`computer path outside /workspace: ${computerPath}`)
}
