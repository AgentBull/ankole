import { safeJsonStringify } from '@agentbull/active-support'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { Buffer } from 'node:buffer'
import { errorMessage } from '../../../common/errors'
import { truncateUTF8Safe, utf8ByteLength } from '../../../common/text-sanitize'
import type { WorkerAgentTool } from '../../index'
import { zodToJSONSchema } from '../../llm/tool-schema'
import { defaultNamespaceDescription } from '../../llm/wire'
import type { DynamicToolCallParams } from '../generated/protocol/v2/DynamicToolCallParams'
import type { DynamicToolCallResponse } from '../generated/protocol/v2/DynamicToolCallResponse'
import type { DynamicToolSpec } from '../generated/protocol/v2/DynamicToolSpec'
import type { JsonValue as JSONValue } from '../generated/protocol/serde_json/JsonValue'

// Bound tool output before it crosses JSON-RPC into the shared app-server.
const maxToolResultBytes = 16_384
const truncationSuffix = '...[truncated]'
// These identity bounds follow the pinned Codex dynamic-tool protocol. Invalid
// tools are quarantined before the app-server can observe them.
const codexDynamicToolNameMaxLength = 128
const codexDynamicNamespaceMaxLength = 64
const codexDynamicNamespaceDescriptionMaxLength = 1_024
const codexDynamicIdentifierPattern = /^[A-Za-z0-9_-]+$/
// Dynamic namespaces cannot replace native MCP or Responses API owners.
const codexReservedResponsesNamespaces = new Set([
  'api_tool',
  'browser',
  'computer',
  'container',
  'file_search',
  'functions',
  'image_gen',
  'multi_tool_use',
  'python',
  'python_user_visible',
  'submodel_delegator',
  'terminal',
  'tool_search',
  'web'
])
/** Default local tools exposed to a Background Agent Job. */
export const codexJobToolPaths = new Set(['web_search', 'web_fetch', 'recall', 'get_page', 'skill_view'])

export type CodexJobProjection = {
  dynamicTools: DynamicToolSpec[]
  quarantinedTools: string[]
  handleToolCall(params: DynamicToolCallParams, signal: AbortSignal): Promise<DynamicToolCallResponse>
}

export function buildCodexJobProjection(input: {
  tools: WorkerAgentTool[]
  allowedToolPaths?: ReadonlySet<string>
  onAudit?: (eventType: string, payload: JSONObject) => void
}): CodexJobProjection {
  const tools = new Map<string, WorkerAgentTool>()
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
    const projectedName = qualifiedToolName(tool.namespace, tool.name)
    if (!(input.allowedToolPaths ?? codexJobToolPaths).has(projectedName)) continue
    try {
      assertCodexDynamicToolIdentity(tool)
      const lookupKey = toolLookupKey(tool.namespace ?? null, tool.name)
      if (tools.has(lookupKey)) throw new Error(`Duplicate dynamic tool ${projectedName}`)
      const inputSchema = (tool.jsonSchema ?? zodToJSONSchema(tool.schema)) as unknown as JSONValue
      if (tool.namespace !== undefined) {
        const existing = namespaces.get(tool.namespace)
        const description = tool.namespaceDescription ?? defaultNamespaceDescription(tool.namespace)
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
        if (tool.deferLoading === true) {
          throw new Error(`Deferred dynamic tool must include a namespace: ${tool.name}`)
        }
        dynamicTools.push({
          type: 'function',
          name: tool.name,
          description: tool.description,
          inputSchema,
          ...(tool.deferLoading === undefined ? {} : { deferLoading: tool.deferLoading })
        })
      }
      tools.set(lookupKey, tool)
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
  return namespace === undefined || namespace === null ? tool : `${namespace}.${tool}`
}

/**
 * Enforces the identifier limits of the pinned Codex protocol.
 * Dynamic identities must not collide with native MCP or Responses namespaces.
 */
function assertCodexDynamicToolIdentity(tool: WorkerAgentTool): void {
  assertCodexDynamicIdentifier(tool.name, 'tool name', codexDynamicToolNameMaxLength)
  if (reservedMCPIdentity(tool.name)) throw new Error(`Dynamic tool name is reserved: ${tool.name}`)
  if (tool.namespace === undefined) return

  assertCodexDynamicIdentifier(tool.namespace, 'tool namespace', codexDynamicNamespaceMaxLength)
  const description = tool.namespaceDescription ?? defaultNamespaceDescription(tool.namespace)
  if ([...description].length > codexDynamicNamespaceDescriptionMaxLength) {
    throw new Error(
      `Dynamic tool namespace description must be at most ${codexDynamicNamespaceDescriptionMaxLength} characters`
    )
  }
  if (reservedMCPIdentity(tool.namespace)) {
    throw new Error(`Dynamic tool namespace is reserved: ${tool.namespace}`)
  }
  if (codexReservedResponsesNamespaces.has(tool.namespace)) {
    throw new Error(`Dynamic tool namespace collides with a reserved Responses API namespace: ${tool.namespace}`)
  }
}

function assertCodexDynamicIdentifier(value: string, label: string, maxLength: number): void {
  if (!value) throw new Error(`Dynamic ${label} must not be empty`)
  if (value.trim() !== value) throw new Error(`Dynamic ${label} has leading or trailing whitespace: ${value}`)
  if (!codexDynamicIdentifierPattern.test(value)) {
    throw new Error(`Dynamic ${label} must match ^[a-zA-Z0-9_-]+$ for the Responses API: ${value}`)
  }
  if ([...value].length > maxLength) {
    throw new Error(`Dynamic ${label} must be at most ${maxLength} characters for the Responses API: ${value}`)
  }
}

function reservedMCPIdentity(value: string): boolean {
  return value === 'mcp' || value.startsWith('mcp__')
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
