import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { Buffer } from 'node:buffer'
import { errorMessage } from '../../common/errors'
import { truncateUTF8Safe, utf8ByteLength } from '../../common/text-sanitize'
import type { AgentTool } from '../../core'
import { zodToJSONSchema } from '../../core/llm/tool-schema'
import type { DynamicToolCallParams } from './generated/protocol/v2/DynamicToolCallParams'
import type { DynamicToolCallResponse } from './generated/protocol/v2/DynamicToolCallResponse'
import type { DynamicToolSpec } from './generated/protocol/v2/DynamicToolSpec'
import type { JsonValue as JSONValue } from './generated/protocol/serde_json/JsonValue'

const maxToolResultBytes = 16_384
const truncationSuffix = '...[truncated]'
const allowedToolNames = new Set([
  'web_search',
  'web_fetch',
  'memory_search',
  'memory_browse',
  'memory_open',
  'memory_update',
  'memory_health_check'
])

export type SubagentProjection = {
  dynamicTools: DynamicToolSpec[]
  quarantinedTools: string[]
  handleToolCall(params: DynamicToolCallParams, signal: AbortSignal): Promise<DynamicToolCallResponse>
}

export function buildSubagentProjection(input: {
  tools: AgentTool[]
  onAudit?: (eventType: string, payload: JSONObject) => void
}): SubagentProjection {
  const tools = new Map<string, AgentTool>()
  const dynamicTools: DynamicToolSpec[] = []
  const quarantinedTools: string[] = []

  for (const tool of input.tools) {
    if (!allowedTool(tool.name)) continue
    try {
      const inputSchema = zodToJSONSchema(tool.schema)
      dynamicTools.push({
        type: 'function',
        name: tool.name,
        description: tool.description,
        inputSchema: inputSchema as unknown as JSONValue
      })
      tools.set(tool.name, tool)
    } catch (error) {
      quarantinedTools.push(tool.name)
      input.onAudit?.('dynamic_tool_quarantined', { tool: tool.name, error: errorMessage(error) })
    }
  }

  return {
    dynamicTools,
    quarantinedTools,
    async handleToolCall(params, signal) {
      const tool = tools.get(params.tool)
      if (!tool) {
        return dynamicToolFailure(`Dynamic tool is unavailable: ${params.tool}`)
      }

      const parsed = tool.schema.safeParse(params.arguments)
      if (!parsed.success) {
        input.onAudit?.('dynamic_tool_invalid_arguments', {
          tool: params.tool,
          call_id: params.callId,
          issues: parsed.error.issues as unknown as JSONObject
        })
        return dynamicToolFailure(`Invalid arguments for ${params.tool}: ${parsed.error.message}`)
      }

      input.onAudit?.('dynamic_tool_started', { tool: params.tool, call_id: params.callId })
      try {
        const result = await tool.execute(params.callId, parsed.data, signal)
        input.onAudit?.('dynamic_tool_completed', { tool: params.tool, call_id: params.callId, success: true })
        return { contentItems: dynamicToolContentItems(result), success: true }
      } catch (error) {
        const message = boundedText(errorMessage(error))
        input.onAudit?.('dynamic_tool_completed', {
          tool: params.tool,
          call_id: params.callId,
          success: false,
          error: message
        })
        return dynamicToolFailure(message)
      }
    }
  }
}

function allowedTool(name: string): boolean {
  return allowedToolNames.has(name) || (name.startsWith('browser_') && name !== 'browser_run')
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
    { type: 'inputText', text: boundedText(text || toolResultDetailsText(result.details)) }
  ]
  for (const part of result.content) {
    const imageURL = toolResultImageURL(part)
    if (imageURL) contentItems.push({ type: 'inputImage', imageUrl: imageURL })
  }
  return contentItems
}

function toolResultDetailsText(details: unknown): string {
  try {
    return JSON.stringify(details)
  } catch {
    return String(details)
  }
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

function imageBytes(value: unknown): Buffer | undefined {
  if (Buffer.isBuffer(value)) return value
  if (value instanceof Uint8Array) return Buffer.from(value.buffer, value.byteOffset, value.byteLength)
  if (value instanceof ArrayBuffer) return Buffer.from(value)
  if (ArrayBuffer.isView(value)) return Buffer.from(value.buffer, value.byteOffset, value.byteLength)
  return undefined
}

function boundedText(text: string): string {
  if (utf8ByteLength(text) <= maxToolResultBytes) return text
  const prefix = truncateUTF8Safe(text, maxToolResultBytes - utf8ByteLength(truncationSuffix))
  return `${prefix}${truncationSuffix}`
}

function dynamicToolFailure(text: string): DynamicToolCallResponse {
  return { contentItems: [{ type: 'inputText', text: boundedText(text) }], success: false }
}
