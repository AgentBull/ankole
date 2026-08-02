import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { Buffer } from 'node:buffer'
import { errorMessage } from '../../common/errors'
import { truncateUTF8Safe, utf8ByteLength } from '../../common/text-sanitize'
import type { AgentTool } from '../index'
import { zodToJSONSchema } from '../llm/tool-schema'
import type { DynamicToolCallParams } from '../../tools/codex/generated/protocol/v2/DynamicToolCallParams'
import type { DynamicToolCallResponse } from '../../tools/codex/generated/protocol/v2/DynamicToolCallResponse'
import type { DynamicToolSpec } from '../../tools/codex/generated/protocol/v2/DynamicToolSpec'
import type { JsonValue as JSONValue } from '../../tools/codex/generated/protocol/serde_json/JsonValue'

const maxToolResultBytes = 16_384
const truncationSuffix = '...[truncated]'
export const codexJobToolNames = new Set([
  'web_search',
  'web_fetch',
  'memory_search',
  'memory_browse',
  'memory_open',
  'memory_update',
  'memory_health_check'
])

export type CodexJobProjection = {
  dynamicTools: DynamicToolSpec[]
  quarantinedTools: string[]
  handleToolCall(params: DynamicToolCallParams, signal: AbortSignal): Promise<DynamicToolCallResponse>
}

export function buildCodexJobProjection(input: {
  tools: AgentTool[]
  allowedToolNames?: ReadonlySet<string>
  onAudit?: (eventType: string, payload: JSONObject) => void
}): CodexJobProjection {
  const tools = new Map<string, AgentTool>()
  const dynamicTools: DynamicToolSpec[] = []
  const namespaces = new Map<
    string,
    {
      description: string
      toolNames: Set<string>
      tools: Extract<DynamicToolSpec, { type: 'namespace' }>['tools']
    }
  >()
  const quarantinedTools: string[] = []

  for (const tool of input.tools) {
    if (!tool.namespace && !(input.allowedToolNames ?? codexJobToolNames).has(tool.name)) continue
    const projectedName = qualifiedToolName(tool.namespace, tool.name)
    try {
      const inputSchema = (tool.jsonSchema ?? zodToJSONSchema(tool.schema)) as unknown as JSONValue
      if (tool.namespace) {
        const existing = namespaces.get(tool.namespace)
        const description = tool.namespaceDescription ?? tool.namespace
        if (existing && existing.description !== description) {
          throw new Error(`Dynamic namespace ${tool.namespace} has conflicting descriptions`)
        }
        const namespace = existing ?? { description, toolNames: new Set<string>(), tools: [] }
        if (namespace.toolNames.has(tool.name)) throw new Error(`Duplicate dynamic tool ${projectedName}`)
        namespace.toolNames.add(tool.name)
        namespace.tools.push({
          type: 'function',
          name: tool.name,
          description: tool.description,
          inputSchema,
          ...(tool.deferLoading === undefined ? {} : { deferLoading: tool.deferLoading })
        })
        namespaces.set(tool.namespace, namespace)
      } else {
        dynamicTools.push({
          type: 'function',
          name: tool.name,
          description: tool.description,
          inputSchema,
          ...(tool.deferLoading === undefined ? {} : { deferLoading: tool.deferLoading })
        })
      }
      tools.set(toolLookupKey(tool.namespace ?? null, tool.name), tool)
    } catch (error) {
      quarantinedTools.push(projectedName)
      input.onAudit?.('dynamic_tool_quarantined', { tool: projectedName, error: errorMessage(error) })
    }
  }

  for (const [name, namespace] of namespaces) {
    dynamicTools.push({
      type: 'namespace',
      name,
      description: namespace.description,
      tools: namespace.tools
    })
  }

  return {
    dynamicTools,
    quarantinedTools,
    async handleToolCall(params, signal) {
      const projectedName = qualifiedToolName(params.namespace, params.tool)
      const tool = tools.get(toolLookupKey(params.namespace, params.tool))
      if (!tool) {
        return dynamicToolFailure(`Dynamic tool is unavailable: ${projectedName}`)
      }

      const parsed = tool.schema.safeParse(params.arguments)
      if (!parsed.success) {
        input.onAudit?.('dynamic_tool_invalid_arguments', {
          tool: projectedName,
          call_id: params.callId,
          issues: parsed.error.issues as unknown as JSONObject
        })
        return dynamicToolFailure(`Invalid arguments for ${projectedName}: ${parsed.error.message}`)
      }

      input.onAudit?.('dynamic_tool_started', { tool: projectedName, call_id: params.callId })
      try {
        const result = await tool.execute(params.callId, parsed.data, signal)
        input.onAudit?.('dynamic_tool_completed', { tool: projectedName, call_id: params.callId, success: true })
        return { contentItems: dynamicToolContentItems(result), success: true }
      } catch (error) {
        const message = boundedText(errorMessage(error))
        input.onAudit?.('dynamic_tool_completed', {
          tool: projectedName,
          call_id: params.callId,
          success: false,
          error: message
        })
        return dynamicToolFailure(message)
      }
    }
  }
}

function toolLookupKey(namespace: string | null, tool: string): string {
  return `${namespace ?? ''}\u0000${tool}`
}

function qualifiedToolName(namespace: string | null | undefined, tool: string): string {
  return namespace ? `${namespace}.${tool}` : tool
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
