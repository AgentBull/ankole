import { createHash } from 'node:crypto'
import { jsonObject, type JsonObject as JSONObject } from '@agentbull/active-support'
import type { ActorTurnRef } from '../../../lanes/actor_lane'
import { rpcMethods, type RPCRequester } from '../../../lanes/rpc_lane'
import { normalizedCollaborationToolName, stringValue } from '../protocol'

/**
 * Rebuilds a lost Codex thread from durable control-plane Turn items.
 * The conversion is intentionally lossy. It omits reasoning and maps each tool
 * call to a name, arguments, and output. Codex compacts long replay input.
 */
export async function fetchReplayTurnItems(
  rpc: RPCRequester,
  turn: ActorTurnRef,
  jobID: string
): Promise<JSONObject[]> {
  const items: JSONObject[] = []
  let cursor = ''
  do {
    const response = await rpc(rpcMethods.backgroundAgentJobTurnItemsList, { jobId: jobID, cursor }, { turn })
    for (const entry of response.items) items.push(parseItemJSON(entry.itemJson))
    cursor = response.nextCursor
  } while (cursor)
  return items
}

function parseItemJSON(bytes: Uint8Array): JSONObject {
  try {
    return jsonObject(JSON.parse(new TextDecoder().decode(bytes)))
  } catch (error) {
    throw new Error('durable Turn item contains invalid JSON', { cause: error })
  }
}

export function wireItemsFromTurnItems(items: JSONObject[]): JSONObject[] {
  return items.flatMap(item => wireItemsFromSemanticItem(item))
}

function wireItemsFromSemanticItem(item: JSONObject): JSONObject[] {
  switch (item.type) {
    case 'userMessage':
      return textMessage('user', 'input_text', userText(item.content))
    case 'hookPrompt':
      return textMessage('developer', 'input_text', jsonText(item.fragments))
    case 'agentMessage':
      return textMessage('assistant', 'output_text', stringValue(item.text) ?? '')
    case 'plan':
      return textMessage('assistant', 'output_text', stringValue(item.text) ?? '')
    case 'commandExecution':
      return toolCallPair(item.id, { name: 'shell' }, { command: item.command, cwd: item.cwd }, commandOutput(item))
    case 'fileChange':
      return toolCallPair(
        item.id,
        { name: 'apply_patch' },
        { changes: item.changes },
        stringValue(item.status) ?? 'completed'
      )
    case 'mcpToolCall':
      return toolCallPair(
        item.id,
        replayMCPToolIdentity(item),
        item.arguments,
        jsonText(item.result ?? item.error ?? '')
      )
    case 'dynamicToolCall':
      return toolCallPair(
        item.id,
        {
          namespace: stringValue(item.namespace),
          name: stringValue(item.tool) ?? 'dynamic_tool'
        },
        item.arguments,
        dynamicToolOutput(item)
      )
    case 'collabAgentToolCall':
      return toolCallPair(
        item.id,
        { namespace: 'collaboration', name: normalizedCollaborationToolName(stringValue(item.tool)) },
        { receiver_thread_ids: item.receiverThreadIds },
        jsonText(item.agentsStates ?? '')
      )
    case 'webSearch':
      return toolCallPair(item.id, { name: 'web_search' }, { query: item.query }, '')
    default:
      // reasoning, contextCompaction, imageView, sleep, imageGeneration and
      // review markers add no replayable state beyond the workspace or the tool
      // pair above.
      return []
  }
}

function commandOutput(item: JSONObject): string {
  const output = stringValue(item.aggregatedOutput) ?? ''
  const exitCode = typeof item.exitCode === 'number' ? `\n[exit_code: ${item.exitCode}]` : ''
  return `${output}${exitCode}`
}

function dynamicToolOutput(item: JSONObject): string {
  if (item.tool === 'request_user_input' && item.status === 'inProgress') {
    return 'The Job was interrupted here to ask for user input.'
  }
  return jsonText(item.contentItems ?? '')
}

function textMessage(role: string, partType: string, text: string): JSONObject[] {
  if (!text) return []
  return [
    {
      type: 'message',
      role,
      content: [{ type: partType, text }]
    }
  ]
}

type ReplayToolIdentity = { namespace?: string; name: string }

function toolCallPair(id: unknown, identity: ReplayToolIdentity, args: unknown, output: string): JSONObject[] {
  const callID = replayCallID(stringValue(id) ?? crypto.randomUUID())
  return [
    {
      type: 'function_call',
      ['call_id']: callID,
      ...(identity.namespace ? { namespace: identity.namespace } : {}),
      name: identity.name,
      arguments: jsonText(args ?? {})
    },
    {
      type: 'function_call_output',
      ['call_id']: callID,
      output
    }
  ]
}

function replayMCPToolIdentity(item: JSONObject): ReplayToolIdentity {
  const namespace = stringValue(item.namespace)
  const name = stringValue(item.name)

  // Older durable turn items predate the model-visible MCP identity fields.
  // Rebuild the common Codex namespace form without flattening it into `name`.
  const server = stringValue(item.server)
  const tool = stringValue(item.tool)
  return {
    ...(namespace
      ? { namespace }
      : server
        ? { namespace: server.startsWith('mcp__') ? server : `mcp__${responsesIdentifier(server)}` }
        : {}),
    name: name ?? (tool ? responsesIdentifier(tool) : 'mcp_tool')
  }
}

function responsesIdentifier(value: string): string {
  return value.replace(/[^A-Za-z0-9_]/gu, '_')
}

function userText(content: unknown): string {
  if (!Array.isArray(content)) return ''
  return content
    .map(part => {
      const value = jsonObject(part)
      if (value.type === 'text') return stringValue(value.text) ?? ''
      return `[${stringValue(value.type) ?? 'attachment'} omitted]`
    })
    .join('')
}

function jsonText(value: unknown): string {
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value ?? '')
  } catch {
    return String(value)
  }
}

export function replayCallID(id: string): string {
  return id.length <= 64 ? id : createHash('sha256').update(id).digest('hex')
}
