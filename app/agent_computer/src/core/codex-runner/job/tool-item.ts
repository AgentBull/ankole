import { jsonObject, type JsonObject } from '@agentbull/active-support'
import { compareCodePointStrings } from '../../../common/ordering'
import { stringValue } from '../../llm/parse'
import { normalizedCollaborationToolName } from '../protocol'

export type ToolIdentity = {
  namespace?: string
  name: string
}

export type ToolExecutionMechanism = ToolIdentity & {
  execution_mechanism: 'provider_hosted' | 'local_dynamic'
}

export type CodexToolItem = {
  id: string
  identity: ToolIdentity
  input?: unknown
  output?: unknown
  executionMechanism?: ToolExecutionMechanism['execution_mechanism']
  durationMs?: number
  errorType?: string
}

export function projectCodexToolItem(item: JsonObject, modelIdentity?: ToolIdentity): CodexToolItem | undefined {
  const id = stringValue(item.id)
  if (!id) return undefined
  const errorCode = stringValue(jsonObject(item.error).code)
  const common = {
    id,
    durationMs: positiveNumber(item.durationMs),
    errorType: errorCode?.trim()
      ? errorCode
      : item.success === false || item.status === 'failed'
        ? 'codex_tool_failed'
        : undefined
  }

  switch (item.type) {
    case 'commandExecution': {
      const output = stringValue(item.aggregatedOutput)
      const exitCode = positiveNumber(item.exitCode)
      return {
        ...common,
        identity: { name: 'shell' },
        input: { command: item.command, cwd: item.cwd },
        output: output === undefined && exitCode === undefined ? undefined : { output, exit_code: exitCode }
      }
    }
    case 'fileChange':
      return { ...common, identity: { name: 'apply_patch' }, input: { changes: item.changes } }
    case 'mcpToolCall': {
      const server = stringValue(item.server)
      const namespace =
        modelIdentity?.namespace ?? stringValue(item.namespace) ?? (server ? mcpNamespace(server) : undefined)
      const tool = stringValue(item.tool)
      const name = modelIdentity?.name ?? stringValue(item.name) ?? (tool ? responsesIdentifier(tool) : undefined)
      return name
        ? {
            ...common,
            identity: { ...(namespace ? { namespace } : {}), name },
            input: item.arguments ?? {},
            output: item.result ?? item.error ?? undefined
          }
        : undefined
    }
    case 'dynamicToolCall': {
      const name = stringValue(item.tool)
      const namespace = stringValue(item.namespace)
      return name
        ? {
            ...common,
            identity: { ...(namespace ? { namespace } : {}), name },
            input: item.arguments ?? {},
            output: item.contentItems ?? undefined,
            executionMechanism: 'local_dynamic'
          }
        : undefined
    }
    case 'collabAgentToolCall': {
      const tool = stringValue(item.tool)
      return tool
        ? {
            ...common,
            identity: { namespace: 'collaboration', name: normalizedCollaborationToolName(tool) },
            executionMechanism: 'local_dynamic'
          }
        : undefined
    }
    case 'webSearch':
      return {
        ...common,
        identity: { name: 'web_search' },
        input: { query: item.query, action: item.action },
        output: item.results ?? undefined,
        executionMechanism: 'provider_hosted'
      }
    case 'imageView':
      return { ...common, identity: { name: 'view_image' }, input: { path: item.path } }
    case 'sleep':
      return { ...common, identity: { name: 'sleep' }, input: { duration_ms: item.durationMs } }
    case 'imageGeneration': {
      const output = { result: item.result, failure: item.failure, saved_path: item.savedPath }
      return {
        ...common,
        identity: { name: 'image_generation' },
        input: { prompt: item.revisedPrompt, transparent_background: item.transparentBackground },
        output: Object.values(output).some(value => value !== undefined) ? output : undefined
      }
    }
    case 'contextCompaction':
      return { ...common, identity: { name: 'context_compaction' } }
    default:
      return undefined
  }
}

function mcpNamespace(server: string): string {
  return server.startsWith('mcp__') ? server : `mcp__${responsesIdentifier(server)}`
}

function responsesIdentifier(value: string): string {
  return value.replace(/[^A-Za-z0-9_]/gu, '_')
}

export function toolIdentityKey(identity: ToolIdentity): string {
  return `${identity.namespace ?? ''}\u0000${identity.name}`
}

export function sameToolIdentity(left: ToolIdentity, right: ToolIdentity): boolean {
  return left.namespace === right.namespace && left.name === right.name
}

export function compareToolIdentity(left: ToolIdentity, right: ToolIdentity): number {
  return compareCodePointStrings(toolIdentityKey(left), toolIdentityKey(right))
}

function positiveNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : undefined
}
