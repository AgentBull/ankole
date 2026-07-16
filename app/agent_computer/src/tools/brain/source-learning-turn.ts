import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { arrayPath, deepString, firstString, isRecord, type JsonObject as JSONObject } from '@pleisto/active-support'
import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import type { TurnStart } from '../../lanes/actor_lane'
import type { MemoryRPCRequester } from '../../lanes/rpc_lane'
import { resolveWorkspacePath } from '../../core/workspace-paths'
import {
  createMemoryBrowseTool,
  createMemoryOpenTool,
  createMemorySearchTool,
  createMemoryUpdateTool
} from '../memory/memory-tools'

export interface SourceLearningTurnTools {
  /** The complete model-visible toolset of one `brain.source.learn` turn. */
  tools: AgentTool<any>[]
  /** Fails the turn when it ends before source_read reported complete=true. */
  assertCompleted(): void
}

/**
 * Assembles the whole worker-side capability surface of one source-learning turn.
 *
 * The turn gets only the snapshot-bound reader, the Brain read tools, and a
 * write-gated memory_update; construction is the authorization, so nothing else
 * can leak in. The control plane's WriteAuthority remains the authoritative gate
 * for allowed operations and source citations.
 */
export function createSourceLearningTurnTools(opts: {
  turnStart: TurnStart
  workspaceRoot: string
  requestMemoryRPC?: MemoryRPCRequester
}): SourceLearningTurnTools {
  if (!opts.requestMemoryRPC) {
    throw new Error('source learning turn requires the Brain memory RPC seam')
  }
  const reader = createBrainSourceLearningReader(opts.turnStart, opts.workspaceRoot)
  const memoryOptions = { turnStart: opts.turnStart, requestMemoryRPC: opts.requestMemoryRPC }
  return {
    tools: [
      reader.tool,
      createMemorySearchTool(memoryOptions),
      createMemoryOpenTool(memoryOptions),
      learningMemoryUpdateTool(createMemoryUpdateTool(memoryOptions), reader),
      createMemoryBrowseTool(memoryOptions)
    ],
    assertCompleted: () => reader.assertCompleted()
  }
}

/**
 * Rebinds memory_update to the learning-run write contract: the description
 * carries the exact src marker WriteAuthority demands, and the write gate stays
 * closed until the retained source has been read completely.
 */
function learningMemoryUpdateTool(tool: AgentTool<any>, reader: BrainSourceLearningReader): AgentTool<any> {
  return {
    ...tool,
    description: `Integrate the retained source into Brain. You may only create_entry with initial_body, append_block, or edit_block, and that body must contain the exact marker src:${reader.documentID}. For create_entry, set only name, type, and initial_body. Open existing entries first and pass the returned lock version.`,
    async execute(toolCallID, params, signal) {
      reader.assertReadyToWrite()
      return tool.execute(toolCallID, params, signal)
    }
  }
}

const SourceReadParams = z.object({
  cursor: z.string().min(1).optional().describe('Opaque cursor returned by the previous source_read page.')
})

type SourceReadDetails = {
  complete: boolean
  documentID: string
  nextCursor?: string
  totalCharacters: number
}

type ReaderState = 'unread' | 'reading' | 'complete' | 'failed'

const maxExtractedCharacters = 500_000
const pageCharacters = 50_000

export interface BrainSourceLearningReader {
  tool: AgentTool<typeof SourceReadParams, SourceReadDetails>
  documentID: string
  assertCompleted(): void
  assertReadyToWrite(): void
}

/**
 * Creates the one-source reader and the completion gate for a source-learning turn.
 *
 * The model cannot choose a path, command, page size, or source identity. The
 * reader verifies the run-local bytes against the control-plane descriptor before
 * extraction and only opens the write gate after the final character page is read.
 */
export function createBrainSourceLearningReader(
  turnStart: TurnStart,
  workspaceRoot: string
): BrainSourceLearningReader {
  const descriptor = sourceDescriptor(turnStart)
  let state: ReaderState = 'unread'
  let failure: string | undefined
  let extracted: Promise<string> | undefined
  let expectedCursor: string | undefined

  const tool: AgentTool<typeof SourceReadParams, SourceReadDetails> = {
    name: 'source_read',
    description:
      'Read the retained source selected for this learning run. Continue with the returned cursor until complete=true. The tool is bound to one byte-verified source and cannot read arbitrary paths.',
    schema: SourceReadParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => `读取资料：${descriptor.title}`,
    async execute(_toolCallID, params): Promise<AgentToolResult<SourceReadDetails>> {
      let content: string
      try {
        extracted ??= extractSource(descriptor, workspaceRoot)
        content = await extracted
      } catch (error) {
        state = 'failed'
        failure = error instanceof Error ? error.message : String(error)
        throw error
      }

      const start = sequentialPageStart(state, params.cursor, expectedCursor, content.length)
      const end = safePageEnd(content, start, pageCharacters)
      const complete = end >= content.length
      const nextCursor = complete ? undefined : encodeCursor(end)
      expectedCursor = nextCursor
      state = complete ? 'complete' : 'reading'

      const continuation = complete
        ? `\n\n[${content.length} characters total; complete=true]`
        : `\n\n[characters ${start + 1}-${end} of ${content.length}; complete=false; continue with cursor=${nextCursor}]`

      return {
        content: [{ type: 'text', text: content.slice(start, end) + continuation }],
        details: {
          complete,
          documentID: descriptor.documentID,
          ...(nextCursor ? { nextCursor } : {}),
          totalCharacters: content.length
        }
      }
    }
  }

  return {
    tool,
    documentID: descriptor.documentID,
    assertReadyToWrite() {
      if (state === 'failed') {
        throw new Error(`retained source read failed: ${failure ?? 'unknown error'}`)
      }
      if (state !== 'complete') {
        throw new Error('memory_update is unavailable until source_read reports complete=true')
      }
    },
    assertCompleted() {
      if (state === 'failed') {
        throw new Error(`retained source learning failed while reading: ${failure ?? 'unknown error'}`)
      }
      if (state !== 'complete') {
        throw new Error('source learning ended before source_read reported complete=true')
      }
    }
  }
}

type SourceDescriptor = {
  byteSize: number
  documentID: string
  mediaType: string
  path: string
  sha256: string
  title: string
}

function sourceDescriptor(turnStart: TurnStart): SourceDescriptor {
  const payload = turnStart.actor_event.payload_json
  const documentID = deepString(payload, ['data', 'retained_source', 'document_id'])
  const title = deepString(payload, ['data', 'retained_source', 'title'])
  const mediaType = deepString(payload, ['data', 'retained_source', 'media_type'])
  const sha256 = deepString(payload, ['data', 'retained_source', 'sha256'])
  const byteSize = deepPositiveInteger(payload, ['data', 'retained_source', 'byte_size'])
  const path = deepString(payload, ['data', 'retained_source', 'path']) ?? attachmentPath(payload)

  if (!documentID || !title || !mediaType || !path || !sha256 || !byteSize || !/^[0-9a-f]{64}$/.test(sha256)) {
    throw new Error('brain source learning event is missing its immutable source descriptor')
  }

  return { byteSize, documentID, mediaType, path, sha256, title }
}

function deepPositiveInteger(value: JSONObject | undefined, path: string[]): number | undefined {
  let current: unknown = value
  for (const segment of path) {
    if (!isRecord(current)) return undefined
    current = current[segment]
  }
  return typeof current === 'number' && Number.isSafeInteger(current) && current > 0 ? current : undefined
}

function attachmentPath(payload: JSONObject | undefined): string | undefined {
  const attachment = arrayPath(payload, ['data', 'entry', 'attachments']).find(value => isRecord(value))
  return attachment && firstString(attachment, ['agent_computer_path', 'path'])
}

async function extractSource(descriptor: SourceDescriptor, workspaceRoot: string): Promise<string> {
  const path = resolveWorkspacePath(workspaceRoot, descriptor.path, {
    errorMessage: 'retained source path escapes the learning workspace'
  })
  const bytes = await readFile(path)
  verifyBytes(bytes, descriptor)
  const mediaType = descriptor.mediaType.toLowerCase()

  if (textMediaType(mediaType)) {
    if (bytes.subarray(0, 8192).includes(0)) {
      throw new Error(`retained source ${descriptor.documentID} claims a text media type but contains binary data`)
    }
    return boundedExtractedText(bytes.toString('utf8'))
  }

  if (mediaType.includes('pdf') || path.toLowerCase().endsWith('.pdf')) {
    return await fixedExtraction(['pdftotext', '-layout', path, '-'])
  }

  return await fixedExtraction(['markitdown', path])
}

function verifyBytes(bytes: Uint8Array, descriptor: SourceDescriptor): void {
  if (bytes.byteLength !== descriptor.byteSize) {
    throw new Error(`retained source byte size mismatch: expected ${descriptor.byteSize}, received ${bytes.byteLength}`)
  }
  const actualHash = createHash('sha256').update(bytes).digest('hex')
  if (actualHash !== descriptor.sha256) {
    throw new Error(`retained source SHA-256 mismatch: expected ${descriptor.sha256}, received ${actualHash}`)
  }
}

function textMediaType(mediaType: string): boolean {
  return (
    mediaType.startsWith('text/') ||
    mediaType.includes('json') ||
    mediaType.includes('xml') ||
    mediaType.includes('yaml')
  )
}

async function fixedExtraction(argv: string[]): Promise<string> {
  const process = Bun.spawn(argv, { stdout: 'pipe', stderr: 'pipe' })
  const [exitCode, stdout, stderr] = await Promise.all([
    process.exited,
    new Response(process.stdout).text(),
    new Response(process.stderr).text()
  ])

  if (exitCode !== 0) {
    throw new Error(`source extraction failed (exit ${exitCode}): ${stderr.trim() || argv[0]}`)
  }

  return boundedExtractedText(stdout)
}

function boundedExtractedText(content: string): string {
  if (!content.trim()) throw new Error('source extraction produced no readable text')
  if (content.length > maxExtractedCharacters) {
    throw new Error(
      `source extraction produced ${content.length} characters, above the ${maxExtractedCharacters} limit`
    )
  }
  return content
}

function encodeCursor(offset: number): string {
  return Buffer.from(`v1:${offset}`, 'utf8').toString('base64url')
}

function decodeCursor(cursor: string | undefined, contentLength: number): number {
  if (!cursor) return 0
  let decoded: string
  try {
    decoded = Buffer.from(cursor, 'base64url').toString('utf8')
  } catch {
    throw new Error('invalid source_read cursor')
  }
  const match = /^v1:(\d+)$/.exec(decoded)
  const offset = match ? Number(match[1]) : Number.NaN
  if (!Number.isSafeInteger(offset) || offset < 0 || offset >= contentLength) {
    throw new Error('invalid source_read cursor')
  }
  return offset
}

function sequentialPageStart(
  state: ReaderState,
  cursor: string | undefined,
  expectedCursor: string | undefined,
  contentLength: number
): number {
  if (state === 'complete') throw new Error('retained source has already been read completely')
  if (state === 'failed') throw new Error('retained source cannot continue after an extraction failure')

  if (state === 'unread') {
    if (cursor) throw new Error('the first source_read call must not include a cursor')
    return 0
  }

  if (!cursor || cursor !== expectedCursor) {
    throw new Error('source_read must continue with the exact cursor returned by the previous page')
  }

  return decodeCursor(cursor, contentLength)
}

function safePageEnd(content: string, start: number, limit: number): number {
  let end = Math.min(content.length, start + limit)
  if (end < content.length && isHighSurrogate(content.charCodeAt(end - 1)) && isLowSurrogate(content.charCodeAt(end))) {
    end -= 1
  }
  return end
}

function isHighSurrogate(code: number): boolean {
  return code >= 0xd800 && code <= 0xdbff
}

function isLowSurrogate(code: number): boolean {
  return code >= 0xdc00 && code <= 0xdfff
}
