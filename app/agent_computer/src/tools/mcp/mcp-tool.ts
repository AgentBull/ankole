import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import type { ActorTurnRef } from '../../lanes/actor_lane'
import type { RuntimeSkillSummary } from '../../lanes/rpc_lane'
import type { SkillFileRoots } from '../../skills/effective-skill'
import { sanitizeBinaryOutput, truncateUTF8Safe, utf8ByteLength } from '../../common/text-sanitize'
import { injectableWorkerEnv } from '../computer/env'
import { callMCPServerTool, type MCPListedTool } from './client'
import { peekMCPServerCatalog, resolveMCPServerCatalog } from './catalog-cache'
import {
  DEFAULT_MCP_TIMEOUT_MS,
  MINIMUM_MCP_TIMEOUT_MS,
  loadEnabledSkillMCPServers,
  type MCPServerConfig
} from './config'

const MAX_DESCRIPTION_BYTES = 512
const MAX_SCHEMA_BYTES = 64 * 1024
const MAX_RESULT_BYTES = 64 * 1024
const MAX_ERROR_BYTES = 2 * 1024
const MAX_VALUE_DEPTH = 12
const MAX_ARRAY_ENTRIES = 128
const MAX_OBJECT_ENTRIES = 256
const MAX_STRING_BYTES = 16 * 1024

const MCPParams = z
  .object({
    action: z.enum(['list', 'describe', 'call']),
    server: z.string().min(1).max(1024).optional(),
    tool: z.string().min(1).max(1024).optional(),
    arguments: z.record(z.string(), z.unknown()).optional(),
    timeout_ms: z.number().int().min(MINIMUM_MCP_TIMEOUT_MS).max(Number.MAX_SAFE_INTEGER).optional()
  })
  .strict()
  .superRefine((params, context) => {
    if (params.action === 'list') {
      if (params.tool || params.arguments) {
        context.addIssue({ code: 'custom', message: 'list does not accept tool or arguments' })
      }
      return
    }

    if (!params.server) {
      context.addIssue({ code: 'custom', path: ['server'], message: `${params.action} requires server` })
    }
    if (!params.tool) context.addIssue({ code: 'custom', path: ['tool'], message: `${params.action} requires tool` })
    if (params.action === 'describe' && params.arguments) {
      context.addIssue({ code: 'custom', path: ['arguments'], message: 'describe does not accept arguments' })
    }
  })

type MCPParams = z.output<typeof MCPParams>

export interface CreateMCPToolsOptions {
  enabledSkills: Array<RuntimeSkillSummary | string>
  skillRoots?: SkillFileRoots
  turn?: ActorTurnRef
  workerEnv?: Record<string, string>
  abortSignal?: AbortSignal
}

/** Creates the main agent's single allowlisted MCP model tool, when configured. */
export async function createMCPTools(options: CreateMCPToolsOptions): Promise<AgentTool[]> {
  const servers = await loadEnabledSkillMCPServers({
    enabledSkills: options.enabledSkills,
    skillRoots: options.skillRoots,
    turn: options.turn
  })
  return servers.length > 0 ? [createMCPTool(servers, options)] : []
}

function createMCPTool(servers: MCPServerConfig[], options: CreateMCPToolsOptions): AgentTool<typeof MCPParams> {
  const serverByName = new Map(servers.map(server => [server.name, server]))
  const secretValues = injectableWorkerEnv(options.workerEnv)
    .map(([, value]) => value)
    .filter(Boolean)
    .sort((left, right) => right.length - left.length)

  return {
    name: 'mcp',
    description:
      'Use MCP capabilities declared by enabled inline Skills. list without server returns allowlisted server names plus any tool summaries already in the bounded worker catalog cache, without opening connections; list with one server lazily discovers only that server and returns bounded tool names/descriptions; describe returns the schema for exactly one selected tool; call invokes exactly one selected tool. Use the Skill routing instructions to select a server, then discover or describe only what is needed.',
    schema: MCPParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    describeActivity: params =>
      params.action === 'list'
        ? '查看 MCP 能力'
        : params.action === 'describe'
          ? `查看 MCP 工具：${boundedLabel(params.server, params.tool)}`
          : `调用 MCP：${boundedLabel(params.server, params.tool)}`,
    async execute(_toolCallID, params, signal): Promise<AgentToolResult<unknown>> {
      const operationSignal = signal ?? options.abortSignal

      try {
        if (params.action === 'list') {
          const selectedServer = params.server ? requiredServer(serverByName, params.server) : undefined
          const listedServers = await Promise.all(
            (selectedServer ? [selectedServer] : servers).map(async server => {
              const tools = selectedServer
                ? await resolveMCPServerCatalog(server, {
                    workerEnv: options.workerEnv,
                    signal: operationSignal,
                    timeoutMs: resolveMCPTimeoutMs(params.timeout_ms, server.timeoutMs)
                  })
                : peekMCPServerCatalog(server, options.workerEnv)
              return listedServer(server, tools)
            })
          )
          return modelResult({ servers: listedServers })
        }

        const server = requiredServer(serverByName, params.server!)
        const timeoutMs = resolveMCPTimeoutMs(params.timeout_ms, server.timeoutMs)
        const tools = await resolveMCPServerCatalog(server, {
          workerEnv: options.workerEnv,
          signal: operationSignal,
          timeoutMs
        })
        const tool = requiredTool(server, tools, params.tool!)

        if (params.action === 'describe') {
          assertBoundedSchema(server.name, tool)
          return modelResult({
            server: server.name,
            tool: {
              name: tool.name,
              ...(tool.description ? { description: boundedDescription(tool.description) } : {}),
              input_schema: tool.inputSchema,
              ...(tool.outputSchema ? { output_schema: tool.outputSchema } : {})
            }
          })
        }

        const result = await callMCPServerTool(server, tool.name, params.arguments ?? {}, {
          workerEnv: options.workerEnv,
          signal: operationSignal,
          timeoutMs
        })
        return modelResult({
          server: server.name,
          tool: tool.name,
          result: boundedMCPResultValue(result, secretValues)
        })
      } catch (error) {
        throw new Error(boundedError(error, secretValues))
      }
    }
  }
}

export function resolveMCPTimeoutMs(requestedTimeoutMs?: number, serverTimeoutMs?: number): number {
  return requestedTimeoutMs ?? serverTimeoutMs ?? DEFAULT_MCP_TIMEOUT_MS
}

function requiredServer(servers: Map<string, MCPServerConfig>, name: string): MCPServerConfig {
  const server = servers.get(name)
  if (!server) throw new Error(`MCP server is not allowlisted by an enabled inline Skill: ${name}`)
  return server
}

function requiredTool(server: MCPServerConfig, tools: MCPListedTool[], name: string): MCPListedTool {
  const tool = tools.find(candidate => candidate.name === name)
  if (!tool) throw new Error(`MCP tool is not exposed by allowlisted server ${server.name}: ${name}`)
  return tool
}

function assertBoundedSchema(serverName: string, tool: MCPListedTool): void {
  const serialized = JSON.stringify({ inputSchema: tool.inputSchema, outputSchema: tool.outputSchema })
  if (utf8ByteLength(serialized) > MAX_SCHEMA_BYTES) {
    throw new Error(`MCP schema exceeds ${MAX_SCHEMA_BYTES} bytes for ${serverName}/${tool.name}`)
  }
}

function modelResult(details: unknown): AgentToolResult<unknown> {
  const text = JSON.stringify(details)
  if (utf8ByteLength(text) > MAX_RESULT_BYTES) {
    throw new Error(`MCP result exceeds ${MAX_RESULT_BYTES} bytes`)
  }
  return { content: [{ type: 'text', text }], details }
}

export function boundedMCPResultValue(value: unknown, secrets: string[], depth = 0): unknown {
  if (depth >= MAX_VALUE_DEPTH) return '[depth limit]'
  if (typeof value === 'string') {
    return boundedString(redactSecrets(sanitizeBinaryOutput(value), secrets), MAX_STRING_BYTES)
  }
  if (value === null || typeof value === 'number' || typeof value === 'boolean') return value
  if (typeof value === 'bigint') return value.toString()
  if (value === undefined) return null
  if (Array.isArray(value)) {
    const entries = value.slice(0, MAX_ARRAY_ENTRIES).map(entry => boundedMCPResultValue(entry, secrets, depth + 1))
    if (value.length > MAX_ARRAY_ENTRIES) entries.push(`[${value.length - MAX_ARRAY_ENTRIES} entries omitted]`)
    return entries
  }
  if (typeof value === 'object') {
    const output = Object.create(null) as Record<string, unknown>
    const entries = Object.entries(value as Record<string, unknown>)
    for (const [key, entry] of entries.slice(0, MAX_OBJECT_ENTRIES)) {
      output[boundedString(redactSecrets(sanitizeBinaryOutput(key), secrets), 512)] = boundedMCPResultValue(
        entry,
        secrets,
        depth + 1
      )
    }
    if (entries.length > MAX_OBJECT_ENTRIES) output._ankole_omitted_entries = entries.length - MAX_OBJECT_ENTRIES
    return output
  }
  return boundedString(String(value), MAX_STRING_BYTES)
}

function boundedDescription(value: string): string {
  return boundedString(sanitizeBinaryOutput(value), MAX_DESCRIPTION_BYTES)
}

function boundedString(value: string, maxBytes: number): string {
  if (utf8ByteLength(value) <= maxBytes) return value
  const suffix = '...[truncated]'
  return `${truncateUTF8Safe(value, maxBytes - utf8ByteLength(suffix))}${suffix}`
}

function boundedError(error: unknown, secrets: string[]): string {
  const message = error instanceof Error ? error.message : String(error)
  return boundedString(redactSecrets(sanitizeBinaryOutput(message), secrets), MAX_ERROR_BYTES)
}

function redactSecrets(value: string, secrets: string[]): string {
  let redacted = value
  for (const secret of secrets) redacted = redacted.replaceAll(secret, '[REDACTED]')
  return redacted
}

function boundedLabel(server: string | undefined, tool: string | undefined): string {
  return boundedString(`${server ?? '?'} / ${tool ?? '?'}`, 160)
}

function listedServer(server: MCPServerConfig, tools?: MCPListedTool[]) {
  return {
    name: server.name,
    ...(server.description ? { description: boundedDescription(server.description) } : {}),
    ...(tools
      ? {
          tools: tools.map(tool => ({
            name: tool.name,
            ...(tool.description ? { description: boundedDescription(tool.description) } : {})
          }))
        }
      : {})
  }
}
