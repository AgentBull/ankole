import { imageBytes } from '../../../common/image-bytes'
import { safeJsonStringify } from '@agentbull/active-support'
import { errorMessage } from '../../../common/errors'
import { truncateUTF8Safe, utf8ByteLength } from '../../../common/text-sanitize'
import type { WorkerAgentTool } from '../../index'
import { zodToJSONSchema } from '../../llm/tool-schema'
import type { DynamicToolCallParams } from '../generated/protocol/v2/DynamicToolCallParams'
import type { DynamicToolCallResponse } from '../generated/protocol/v2/DynamicToolCallResponse'
import type { DynamicToolSpec } from '../generated/protocol/v2/DynamicToolSpec'
import type { JsonValue as JSONValue } from '../generated/protocol/serde_json/JsonValue'

// Bound tool output before it crosses JSON-RPC into the shared app-server.
const maxToolResultBytes = 16_384
const truncationSuffix = '...[truncated]'
const codexJobToolPaths = new Set(['web_search', 'web_fetch', 'skill_view'])

export type CodexJobProjection = {
  dynamicTools: DynamicToolSpec[]
  quarantinedTools: string[]
  handleToolCall(params: DynamicToolCallParams, signal: AbortSignal): Promise<DynamicToolCallResponse>
}

export function buildCodexJobProjection(input: { tools: WorkerAgentTool[] }): CodexJobProjection {
  const tools = new Map<string, WorkerAgentTool>()
  const dynamicTools: DynamicToolSpec[] = []
  const quarantinedTools: string[] = []

  for (const tool of input.tools) {
    if (tool.namespace !== undefined || !codexJobToolPaths.has(tool.name)) continue
    try {
      if (tools.has(tool.name)) throw new Error(`Duplicate dynamic tool ${tool.name}`)
      const inputSchema = (tool.jsonSchema ?? zodToJSONSchema(tool.schema)) as unknown as JSONValue
      dynamicTools.push({ type: 'function', name: tool.name, description: tool.description, inputSchema })
      tools.set(tool.name, tool)
    } catch {
      quarantinedTools.push(tool.name)
    }
  }

  return {
    dynamicTools,
    quarantinedTools,
    async handleToolCall(params, signal) {
      const projectedName = params.namespace == null ? params.tool : `${params.namespace}.${params.tool}`
      const tool = params.namespace == null ? tools.get(params.tool) : undefined
      if (!tool) return dynamicToolFailure(`Dynamic tool is unavailable: ${projectedName}`)
      const parsed = tool.schema.safeParse(params.arguments)
      if (!parsed.success) {
        return dynamicToolFailure(`Invalid arguments for ${projectedName}: ${parsed.error.message}`)
      }
      try {
        const result = await tool.execute(params.callId, parsed.data, signal)
        return { contentItems: dynamicToolContentItems(result), success: true }
      } catch (error) {
        return dynamicToolFailure(errorMessage(error))
      }
    }
  }
}

function dynamicToolContentItems(result: {
  content: unknown[]
  details: unknown
}): DynamicToolCallResponse['contentItems'] {
  const text = result.content
    .map(part => {
      if (!part || typeof part !== 'object') return undefined
      const value = part as { type?: unknown; text?: unknown }
      return value.type === 'text' && typeof value.text === 'string' ? value.text : undefined
    })
    .filter((value): value is string => Boolean(value))
    .join('\n')

  const contentItems: DynamicToolCallResponse['contentItems'] = [
    { type: 'inputText', text: boundedText(text || safeJsonStringify(result.details)) }
  ]
  for (const part of result.content) {
    const imageURL = toolResultImageURL(part)
    if (imageURL) contentItems.push({ type: 'inputImage', imageUrl: imageURL })
  }
  return contentItems
}

function toolResultImageURL(part: unknown): string | undefined {
  if (!part || typeof part !== 'object') return undefined
  const value = part as { type?: unknown; image?: unknown; mimeType?: unknown }
  if (value.type !== 'image') return undefined
  if (typeof value.image === 'string') return value.image
  if (value.image instanceof URL) return value.image.toString()

  const bytes = imageBytes(value.image)
  if (!bytes) return undefined
  const mimeType = typeof value.mimeType === 'string' ? value.mimeType : 'application/octet-stream'
  return `data:${mimeType};base64,${bytes.toString('base64')}`
}

function boundedText(text: string): string {
  if (utf8ByteLength(text) <= maxToolResultBytes) return text
  const prefix = truncateUTF8Safe(text, maxToolResultBytes - utf8ByteLength(truncationSuffix))
  return `${prefix}${truncationSuffix}`
}

function dynamicToolFailure(text: string): DynamicToolCallResponse {
  return { contentItems: [{ type: 'inputText', text: boundedText(text) }], success: false }
}
