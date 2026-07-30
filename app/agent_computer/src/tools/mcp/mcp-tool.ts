import { createHash } from 'node:crypto'
import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import type { ActorTurnRef } from '../../lanes/actor_lane'
import type { RuntimeSkillSummary } from '../../lanes/rpc_lane'
import type { SkillFileRoots } from '../../skills/effective-skill'
import { sanitizeBinaryOutput, truncateUTF8Safe, utf8ByteLength } from '../../common/text-sanitize'
import { injectableWorkerEnv } from '../computer/env'
import { callMCPServerTool, type MCPListedTool, type MCPServerCatalog } from './client'
import { resolveMCPServerCatalog } from './catalog-cache'
import { DEFAULT_MCP_TIMEOUT_MS, loadEnabledSkillMCPServers, type MCPServerConfig } from './config'
import { codexMCPInputSchema } from './json-schema'
import { compareCodePointStrings } from './ordering'

const MAX_RESULT_BYTES = 64 * 1024
const MAX_ERROR_BYTES = 2 * 1024
const MAX_VALUE_DEPTH = 12
const MAX_ARRAY_ENTRIES = 128
const MAX_OBJECT_ENTRIES = 256
const MAX_STRING_BYTES = 16 * 1024
const MCPArguments = z.record(z.string(), z.unknown())

export interface CreateMCPToolsOptions {
  enabledSkills: Array<RuntimeSkillSummary | string>
  skillRoots?: SkillFileRoots
  turn?: ActorTurnRef
  workerEnv?: Record<string, string>
  abortSignal?: AbortSignal
  onCatalogUnavailable?: (failure: MCPCatalogUnavailable) => void
}

export interface MCPCatalogUnavailable {
  serverName: string
  sourceSkills: string[]
  message: string
  code?: string
}

/**
 * Exposes enabled MCP catalogs as deferred Responses namespace functions.
 *
 * Catalog discovery stays in the worker. AIGateway receives the official
 * namespace and `defer_loading` shapes, searches them, and returns only the
 * selected child functions to the model.
 */
export async function createMCPTools(options: CreateMCPToolsOptions): Promise<AgentTool[]> {
  const servers = await loadEnabledSkillMCPServers({
    enabledSkills: options.enabledSkills,
    skillRoots: options.skillRoots,
    turn: options.turn
  })
  const secretValues = workerEnvSecretValues(options.workerEnv)
  const catalogResults = await Promise.all(
    servers.map(async server => {
      try {
        return {
          server,
          catalog: await resolveMCPServerCatalog(server, {
            workerEnv: options.workerEnv,
            signal: options.abortSignal,
            timeoutMs: resolveMCPTimeoutMs(undefined, server.timeoutMs)
          })
        }
      } catch (error) {
        if (options.abortSignal?.aborted) throw error
        options.onCatalogUnavailable?.({
          serverName: server.name,
          sourceSkills: server.sourceSkills,
          message: boundedError(error, secretValues),
          ...boundedErrorCode(error)
        })
        return undefined
      }
    })
  )
  const catalogs = catalogResults.filter(result => result !== undefined)

  return projectMCPTools(catalogs).map(projected => createMCPTool(projected, options))
}

interface ProjectedMCPTool {
  server: MCPServerConfig
  tool: MCPListedTool
  name: string
  namespace: string
  namespaceDescription: string
  searchText: string
  jsonSchema: Record<string, unknown>
}

function createMCPTool(projected: ProjectedMCPTool, options: CreateMCPToolsOptions): AgentTool<typeof MCPArguments> {
  const { server, tool } = projected
  const readOnly = tool.annotations?.readOnlyHint === true
  const secretValues = workerEnvSecretValues(options.workerEnv)

  return {
    name: projected.name,
    description: tool.description ?? '',
    schema: MCPArguments,
    jsonSchema: projected.jsonSchema,
    namespace: projected.namespace,
    namespaceDescription: projected.namespaceDescription,
    deferLoading: true,
    toolSearchText: projected.searchText,
    allowedCallers: ['direct', 'programmatic'],
    executionMode: readOnly ? 'parallel' : 'sequential',
    isReadOnly: readOnly,
    isDestructive: !readOnly,
    describeActivity: () => `调用 MCP：${boundedLabel(server.name, tool.name)}`,
    async execute(_toolCallID, args, signal): Promise<AgentToolResult<unknown>> {
      try {
        const result = await callMCPServerTool(server, tool.name, args, {
          workerEnv: options.workerEnv,
          signal: signal ?? options.abortSignal,
          timeoutMs: resolveMCPTimeoutMs(undefined, server.timeoutMs)
        })
        return modelResult(boundedMCPResultValue(result, secretValues))
      } catch (error) {
        return modelResult({
          content: [{ type: 'text', text: boundedError(error, secretValues) }],
          isError: true
        })
      }
    }
  }
}

export function resolveMCPTimeoutMs(requestedTimeoutMs?: number, serverTimeoutMs?: number): number {
  return requestedTimeoutMs ?? serverTimeoutMs ?? DEFAULT_MCP_TIMEOUT_MS
}

interface MCPToolCandidate {
  server: MCPServerConfig
  catalog: MCPServerCatalog
  tool: MCPListedTool
  rawNamespaceIdentity: string
  rawToolIdentity: string
  namespace: string
  name: string
}

function projectMCPTools(catalogs: Array<{ server: MCPServerConfig; catalog: MCPServerCatalog }>): ProjectedMCPTool[] {
  const seenRawNames = new Set<string>()
  const candidates: MCPToolCandidate[] = []

  for (const { server, catalog } of catalogs) {
    for (const tool of catalog.tools) {
      if (!toolAllowed(server, tool.name)) continue
      const rawNamespaceIdentity = `${server.name}\0${server.name}\0`
      const rawToolIdentity = `${rawNamespaceIdentity}\0${tool.name}\0${tool.name}`
      if (seenRawNames.has(rawToolIdentity)) continue
      seenRawNames.add(rawToolIdentity)
      const sanitizedNamespace = sanitizeResponsesToolName(server.name)
      candidates.push({
        server,
        catalog,
        tool,
        rawNamespaceIdentity,
        rawToolIdentity,
        namespace: sanitizedNamespace.startsWith('mcp__') ? sanitizedNamespace : `mcp__${sanitizedNamespace}`,
        name: sanitizeResponsesToolName(tool.name)
      })
    }
  }

  const namespaceIdentities = new Map<string, Set<string>>()
  for (const candidate of candidates) {
    const identities = namespaceIdentities.get(candidate.namespace) ?? new Set<string>()
    identities.add(candidate.rawNamespaceIdentity)
    namespaceIdentities.set(candidate.namespace, identities)
  }
  for (const candidate of candidates) {
    if ((namespaceIdentities.get(candidate.namespace)?.size ?? 0) > 1) {
      candidate.namespace = appendNamespaceHashSuffix(candidate.namespace, candidate.rawNamespaceIdentity)
    }
  }

  const toolIdentities = new Map<string, Set<string>>()
  for (const candidate of candidates) {
    const key = `${candidate.namespace}\0${candidate.name}`
    const identities = toolIdentities.get(key) ?? new Set<string>()
    identities.add(candidate.rawToolIdentity)
    toolIdentities.set(key, identities)
  }
  for (const candidate of candidates) {
    if ((toolIdentities.get(`${candidate.namespace}\0${candidate.name}`)?.size ?? 0) > 1) {
      candidate.name = appendHashSuffix(candidate.name, candidate.rawToolIdentity)
    }
  }

  candidates.sort((left, right) => compareCodePointStrings(left.rawToolIdentity, right.rawToolIdentity))
  const usedNames = new Set<string>()

  return candidates.flatMap(candidate => {
    ;[candidate.namespace, candidate.name] = uniqueCallableParts(
      candidate.namespace,
      candidate.name,
      candidate.rawToolIdentity,
      usedNames
    )
    if (!toolIsModelVisible(candidate.tool)) return []

    const namespaceDescription = candidate.catalog.instructions?.trim() ?? ''
    const jsonSchema = codexMCPInputSchema(candidate.tool.inputSchema)
    if (!jsonSchema) return []
    return [
      {
        server: candidate.server,
        tool: candidate.tool,
        name: candidate.name,
        namespace: candidate.namespace,
        namespaceDescription,
        searchText: mcpSearchText(candidate, namespaceDescription),
        jsonSchema
      }
    ]
  })
}

function toolAllowed(server: MCPServerConfig, rawToolName: string): boolean {
  if (server.enabledTools && !server.enabledTools.includes(rawToolName)) return false
  return !server.disabledTools?.includes(rawToolName)
}

function toolIsModelVisible(tool: MCPListedTool): boolean {
  const visibility = nestedValue(tool._meta, 'ui', 'visibility')
  if (!Array.isArray(visibility)) return true
  return visibility.some(target => target === 'model')
}

function nestedValue(value: unknown, first: string, second: string): unknown {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined
  const nested = (value as Record<string, unknown>)[first]
  if (!nested || typeof nested !== 'object' || Array.isArray(nested)) return undefined
  return (nested as Record<string, unknown>)[second]
}

function mcpSearchText(candidate: MCPToolCandidate, namespaceDescription: string): string {
  const properties = candidate.tool.inputSchema.properties
  const propertyNames =
    properties && typeof properties === 'object' && !Array.isArray(properties)
      ? Object.keys(properties).sort(compareCodePointStrings)
      : []

  return [
    `${candidate.namespace}${candidate.name}`,
    `${candidate.namespace}__${candidate.name}`,
    candidate.name,
    candidate.tool.name,
    candidate.server.name,
    candidate.tool.title,
    candidate.tool.description,
    namespaceDescription,
    ...propertyNames
  ]
    .filter((part): part is string => typeof part === 'string' && part.trim().length > 0)
    .join(' ')
}

function sanitizeResponsesToolName(value: string): string {
  let sanitized = ''
  for (const character of value) {
    sanitized += /^[A-Za-z0-9_]$/.test(character) ? character : '_'
  }
  return sanitized || '_'
}

const MAX_TOOL_NAME_LENGTH = 64
const CALLABLE_NAME_HASH_LENGTH = 12
const TOOL_NAME_DELIMITER_LENGTH = 2

function hashSuffix(rawIdentity: string): string {
  return `_${createHash('sha1').update(rawIdentity).digest('hex').slice(0, CALLABLE_NAME_HASH_LENGTH)}`
}

function appendHashSuffix(value: string, rawIdentity: string): string {
  return `${value}${hashSuffix(rawIdentity)}`
}

function appendNamespaceHashSuffix(namespace: string, rawIdentity: string): string {
  return namespace.endsWith('__')
    ? `${namespace.slice(0, -2)}${hashSuffix(rawIdentity)}__`
    : appendHashSuffix(namespace, rawIdentity)
}

function uniqueCallableParts(
  namespace: string,
  name: string,
  rawIdentity: string,
  usedNames: Set<string>
): [string, string] {
  const modelName = `${namespace}${name}`
  if (modelName.length + TOOL_NAME_DELIMITER_LENGTH <= MAX_TOOL_NAME_LENGTH && !usedNames.has(modelName)) {
    usedNames.add(modelName)
    return [namespace, name]
  }

  for (let attempt = 0; ; attempt += 1) {
    const hashInput = attempt === 0 ? rawIdentity : `${rawIdentity}\0${attempt}`
    const parts = fitCallablePartsWithHash(namespace, name, hashInput)
    const candidateName = `${parts[0]}${parts[1]}`
    if (usedNames.has(candidateName)) continue
    usedNames.add(candidateName)
    return parts
  }
}

function fitCallablePartsWithHash(namespace: string, name: string, rawIdentity: string): [string, string] {
  const suffix = hashSuffix(rawIdentity)
  const maxToolLength = Math.max(MAX_TOOL_NAME_LENGTH - namespace.length - TOOL_NAME_DELIMITER_LENGTH, 0)
  if (maxToolLength >= suffix.length) {
    return [namespace, `${name.slice(0, maxToolLength - suffix.length)}${suffix}`]
  }

  const maxNamespaceLength = Math.max(MAX_TOOL_NAME_LENGTH - suffix.length - TOOL_NAME_DELIMITER_LENGTH, 0)
  return [namespace.slice(0, maxNamespaceLength), suffix]
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

function boundedString(value: string, maxBytes: number): string {
  if (utf8ByteLength(value) <= maxBytes) return value
  const suffix = '...[truncated]'
  return `${truncateUTF8Safe(value, maxBytes - utf8ByteLength(suffix))}${suffix}`
}

function boundedError(error: unknown, secrets: string[]): string {
  const message = error instanceof Error ? error.message : String(error)
  return boundedString(redactSecrets(sanitizeBinaryOutput(message), secrets), MAX_ERROR_BYTES)
}

function boundedErrorCode(error: unknown): { code?: string } {
  if (!error || typeof error !== 'object') return {}
  const code = Reflect.get(error, 'code')
  if (typeof code !== 'string') return {}
  return { code: boundedString(sanitizeBinaryOutput(code), 160) }
}

function workerEnvSecretValues(workerEnv?: Record<string, string>): string[] {
  return injectableWorkerEnv(workerEnv)
    .map(([, value]) => value)
    .filter(Boolean)
    .sort((left, right) => right.length - left.length)
}

function redactSecrets(value: string, secrets: string[]): string {
  let redacted = value
  for (const secret of secrets) redacted = redacted.replaceAll(secret, '[REDACTED]')
  return redacted
}

function boundedLabel(server: string, tool: string): string {
  return boundedString(`${server} / ${tool}`, 160)
}
