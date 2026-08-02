import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { arrayPath, deepString, firstString, isRecord, type JsonObject as JSONObject } from '@agentbull/active-support'
import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import type { TurnStart } from '../../lanes/actor_lane'
import type { MemoryRPCRequester } from '../../lanes/rpc_lane'
import { assertExistingPathWithin, workspacePhysicalRoots } from '../../core/real-path-boundary'
import { resolveAgentHomePath } from '../../core/agent-home-paths'
import {
  createMemoryBrowseTool,
  createMemoryOpenTool,
  createMemorySearchTool,
  createMemoryUpdateTool
} from '../memory/memory-tools'
import { MemoryModelReferences } from '../memory/model-references'

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
  agentHome?: string
  workspaceRoot: string
  requestMemoryRPC: MemoryRPCRequester
}): SourceLearningTurnTools {
  const modelReferences = new MemoryModelReferences()
  const reader = createBrainSourceLearningReader(
    opts.turnStart,
    opts.agentHome ?? opts.workspaceRoot,
    opts.workspaceRoot,
    modelReferences
  )
  const memoryOptions = {
    turnStart: opts.turnStart,
    requestMemoryRPC: opts.requestMemoryRPC,
    modelReferences
  }
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
    description: `Integrate the retained source into long-term memory. You may only create_entry with initial_body, append_block, or edit_block, and that body must contain the exact marker src:${reader.source}. For create_entry, set only name, type, and initial_body. Open existing entries immediately before updating them.`,
    async execute(toolCallID, params, signal) {
      reader.assertReadyToWrite()
      return tool.execute(toolCallID, params, signal)
    }
  }
}

const SourceReadParams = z.object({}).strict()

type SourceReadDetails = {
  complete: boolean
  source: string
  totalCharacters: number
}

type ReaderState = 'unread' | 'reading' | 'complete' | 'failed'

const maxExtractedCharacters = 500_000
const pageCharacters = 50_000

export interface BrainSourceLearningReader {
  tool: AgentTool<typeof SourceReadParams, SourceReadDetails>
  documentID: string
  source: string
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
  agentHome: string,
  workspaceRoot: string = agentHome,
  modelReferences: MemoryModelReferences = new MemoryModelReferences()
): BrainSourceLearningReader {
  const descriptor = sourceDescriptor(turnStart)
  const source = modelReferences.registerSource(descriptor.documentID)
  let state: ReaderState = 'unread'
  let failure: string | undefined
  let extracted: Promise<string> | undefined
  let offset = 0

  const tool: AgentTool<typeof SourceReadParams, SourceReadDetails> = {
    name: 'source_read',
    description:
      'Read the next part of the retained source selected for this learning run. Call again until complete=true. The tool is bound to one byte-verified source and cannot read arbitrary paths.',
    schema: SourceReadParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => `读取资料：${descriptor.title}`,
    async execute(_toolCallID, _params): Promise<AgentToolResult<SourceReadDetails>> {
      if (state === 'complete') throw new Error('retained source has already been read completely')
      if (state === 'failed') throw new Error('retained source cannot continue after an extraction failure')

      let content: string
      try {
        extracted ??= extractSource(descriptor, agentHome, workspaceRoot)
        content = await extracted
      } catch (error) {
        state = 'failed'
        failure = error instanceof Error ? error.message : String(error)
        throw error
      }

      const start = offset
      const end = safePageEnd(content, start, pageCharacters)
      const complete = end >= content.length
      offset = end
      state = complete ? 'complete' : 'reading'

      const continuation = complete
        ? `\n\n[${content.length} characters total; complete=true]`
        : `\n\n[characters ${start + 1}-${end} of ${content.length}; complete=false; call source_read again]`

      return {
        content: [{ type: 'text', text: content.slice(start, end) + continuation }],
        details: {
          complete,
          source,
          totalCharacters: content.length
        }
      }
    }
  }

  return {
    tool,
    documentID: descriptor.documentID,
    source,
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

async function extractSource(descriptor: SourceDescriptor, agentHome: string, workspaceRoot: string): Promise<string> {
  const lexicalPath = resolveAgentHomePath(agentHome, descriptor.path, {
    cwd: workspaceRoot,
    errorMessage: 'retained source path escapes the learning workspace'
  })
  const path = assertExistingPathWithin(
    workspacePhysicalRoots(agentHome),
    lexicalPath,
    'retained source path resolves outside workspace roots'
  )
  const bytes = await readFile(path)
  verifyBytes(bytes, descriptor)
  const mediaType = descriptor.mediaType.toLowerCase()

  if (textMediaType(mediaType)) {
    if (bytes.subarray(0, 8192).includes(0)) {
      throw new Error('retained source claims a text media type but contains binary data')
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
