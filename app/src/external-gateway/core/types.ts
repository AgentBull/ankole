/**
 * Shared value types for External Gateway adapter I/O and future rich output.
 *
 * Runtime delivery uses `core/events.ts`; this module only keeps the small
 * structures needed by normalized events, markdown output, postable objects,
 * and streaming chunks.
 */

import type { Root } from 'mdast'

export interface Adapter<TRawMessage = unknown> {
  readonly name?: string
  postObject?(threadId: string, kind: string, data: unknown): Promise<RawMessage<TRawMessage>>
}

export type StreamChunk = MarkdownTextChunk | TaskUpdateChunk | PlanUpdateChunk

export interface MarkdownTextChunk {
  text: string
  type: 'markdown_text'
}

export interface TaskUpdateChunk {
  details?: string
  id: string
  output?: string
  status: 'pending' | 'in_progress' | 'complete' | 'error'
  title: string
  type: 'task_update'
}

export interface PlanUpdateChunk {
  title: string
  type: 'plan_update'
}

export interface StreamOptions {
  recipientTeamId?: string
  recipientUserId?: string
  stopBlocks?: unknown[]
  taskDisplayMode?: 'timeline' | 'plan'
  updateIntervalMs?: number
}

export type FormattedContent = Root

export interface RawMessage<TRawMessage = unknown> {
  id: string
  raw: TRawMessage
  threadId: string
}

export interface Author {
  fullName: string
  isBot: boolean | 'unknown'
  isMe: boolean
  userId: string
  userName: string
}

export type AdapterPostableMessage = string | PostableRaw | PostableMarkdown | PostableAst

export type PostableMessage = AdapterPostableMessage | AsyncIterable<string | StreamChunk>

export interface PostableRaw {
  attachments?: Attachment[]
  files?: FileUpload[]
  raw: string | Record<string, unknown>
}

export interface PostableMarkdown {
  attachments?: Attachment[]
  files?: FileUpload[]
  markdown: string
}

export interface PostableAst {
  ast: Root
  attachments?: Attachment[]
  files?: FileUpload[]
}

export interface Attachment {
  data?: Buffer | Blob
  fetchData?: () => Promise<Buffer>
  fetchMetadata?: Record<string, string>
  height?: number
  mimeType?: string
  name?: string
  size?: number
  type: 'image' | 'file' | 'video' | 'audio'
  url?: string
  width?: number
}

export interface LinkPreview {
  description?: string
  fetchMessage?: () => Promise<unknown>
  imageUrl?: string
  siteName?: string
  title?: string
  url: string
}

export interface FileUpload {
  data: Buffer | Blob | ArrayBuffer
  filename: string
  mimeType?: string
}

export type WellKnownEmoji =
  | 'thumbs_up'
  | 'thumbs_down'
  | 'clap'
  | 'wave'
  | 'pray'
  | 'muscle'
  | 'ok_hand'
  | 'point_up'
  | 'point_down'
  | 'point_left'
  | 'point_right'
  | 'raised_hands'
  | 'shrug'
  | 'facepalm'
  | 'heart'
  | 'smile'
  | 'laugh'
  | 'thinking'
  | 'sad'
  | 'cry'
  | 'angry'
  | 'love_eyes'
  | 'cool'
  | 'wink'
  | 'surprised'
  | 'worried'
  | 'confused'
  | 'neutral'
  | 'sleeping'
  | 'sick'
  | 'mind_blown'
  | 'relieved'
  | 'grimace'
  | 'rolling_eyes'
  | 'hug'
  | 'zany'
  | 'check'
  | 'x'
  | 'question'
  | 'exclamation'
  | 'warning'
  | 'stop'
  | 'info'
  | '100'
  | 'fire'
  | 'star'
  | 'sparkles'
  | 'lightning'
  | 'boom'
  | 'eyes'
  | 'green_circle'
  | 'yellow_circle'
  | 'red_circle'
  | 'blue_circle'
  | 'white_circle'
  | 'black_circle'
  | 'rocket'
  | 'party'
  | 'confetti'
  | 'balloon'
  | 'gift'
  | 'trophy'
  | 'medal'
  | 'lightbulb'
  | 'gear'
  | 'wrench'
  | 'hammer'
  | 'bug'
  | 'link'
  | 'lock'
  | 'unlock'
  | 'key'
  | 'pin'
  | 'memo'
  | 'clipboard'
  | 'calendar'
  | 'clock'
  | 'hourglass'
  | 'bell'
  | 'megaphone'
  | 'speech_bubble'
  | 'email'
  | 'inbox'
  | 'outbox'
  | 'package'
  | 'folder'
  | 'file'
  | 'chart_up'
  | 'chart_down'
  | 'coffee'
  | 'pizza'
  | 'beer'
  | 'arrow_up'
  | 'arrow_down'
  | 'arrow_left'
  | 'arrow_right'
  | 'refresh'
  | 'sun'
  | 'cloud'
  | 'rain'
  | 'snow'
  | 'rainbow'

export interface EmojiFormats {
  gchat: string | string[]
  slack: string | string[]
}

// biome-ignore lint/suspicious/noEmptyInterface: Required for TypeScript module augmentation.
export interface CustomEmojiMap {}

export type Emoji = WellKnownEmoji | keyof CustomEmojiMap

export type EmojiMapConfig = Partial<Record<Emoji, EmojiFormats>>

export interface EmojiValue {
  readonly name: string
  toJSON(): string
  toString(): string
}
