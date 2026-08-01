import { randomUUID } from 'node:crypto'
import { lstat, mkdir, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { AjvJsonSchemaValidator } from '@modelcontextprotocol/sdk/validation/ajv'
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js'
import { z } from 'zod'
import type { AgentTool, AgentToolResult, ContentPart } from '../../core'
import { VISION_MAX_INPUT_IMAGE_BYTES } from '../../core/vision'
import { sanitizeBinaryOutput, truncateUTF8Safe, utf8ByteLength } from '../../common/text-sanitize'
import {
  callDirectMCPServerTool,
  listDirectMCPServerCatalog,
  type DirectMCPListedTool,
  type DirectMCPServerCatalog
} from './client'
import { registeredDirectMCPServers, type DirectStdioMCPServer } from './direct-registry'

const maxResultTextBytes = 64 * 1024
const maxErrorBytes = 2 * 1024
const maxValueDepth = 12
const maxArrayEntries = 128
const maxObjectEntries = 256
const maxStringBytes = 16 * 1024
const DirectMCPArguments = z.record(z.string(), z.unknown())

type OutputValidator = ReturnType<AjvJsonSchemaValidator['getValidator']>
const catalogCache = new Map<string, DirectMCPServerCatalog>()

export interface DirectMCPCatalogUnavailable {
  serverName: string
  message: string
}

export interface CreateDirectMCPToolsOptions {
  artifactRoot: string
  workerEnv?: Record<string, string>
  abortSignal?: AbortSignal
  servers?: DirectStdioMCPServer[]
  onCatalogUnavailable?: (failure: DirectMCPCatalogUnavailable) => void
}

/** Builds the model-visible tools from every release-defined Direct MCP server. */
export async function createDirectMCPTools(options: CreateDirectMCPToolsOptions): Promise<AgentTool[]> {
  const servers = options.servers ?? registeredDirectMCPServers()
  const projectedTools = await Promise.all(
    servers.map(async server => {
      try {
        const catalog = await resolveCatalog(server, options)
        return projectCatalog(server, catalog, options)
      } catch (error) {
        if (options.abortSignal?.aborted) throw error
        options.onCatalogUnavailable?.({
          serverName: server.name,
          message: boundedError(error, secretValues(server, options.workerEnv))
        })
        return []
      }
    })
  )

  return projectedTools.flat()
}

async function resolveCatalog(
  server: DirectStdioMCPServer,
  options: Pick<CreateDirectMCPToolsOptions, 'workerEnv' | 'abortSignal'>
): Promise<DirectMCPServerCatalog> {
  const key = catalogCacheKey(server)
  const cached = catalogCache.get(key)
  if (cached) return cached

  const catalog = await listDirectMCPServerCatalog(server, {
    workerEnv: options.workerEnv,
    signal: options.abortSignal
  })
  const secrets = secretValues(server, options.workerEnv)
  if (secrets.length > 0 && containsSecret(catalog, secrets)) {
    throw new Error(`Direct MCP server ${server.name} returned WorkerEnv data in its catalog`)
  }
  catalogCache.set(key, catalog)
  return catalog
}

function projectCatalog(
  server: DirectStdioMCPServer,
  catalog: DirectMCPServerCatalog,
  options: CreateDirectMCPToolsOptions
): AgentTool[] {
  assertCallableName(server.namespace, 'Direct MCP namespace')
  const tools = catalog.tools.filter(tool => server.enabledTools.includes(tool.name) && toolIsModelVisible(tool))
  const projectedNames = new Set<string>()

  return tools.map(tool => {
    assertCallableName(tool.name, `Direct MCP tool ${server.name}`)
    const providerName = `${server.namespace}__${tool.name}`
    if (providerName.length > 64) throw new Error(`Direct MCP tool name exceeds 64 characters: ${providerName}`)
    if (projectedNames.has(providerName)) throw new Error(`Direct MCP tool name collision: ${providerName}`)
    projectedNames.add(providerName)

    const outputValidator = tool.outputSchema ? new AjvJsonSchemaValidator().getValidator(tool.outputSchema) : undefined
    return createDirectMCPTool(server, tool, outputValidator, options)
  })
}

function createDirectMCPTool(
  server: DirectStdioMCPServer,
  tool: DirectMCPListedTool,
  outputValidator: OutputValidator | undefined,
  options: CreateDirectMCPToolsOptions
): AgentTool<typeof DirectMCPArguments> {
  const readOnly = tool.annotations?.readOnlyHint === true
  const destructive = tool.annotations?.destructiveHint === true
  const parallel = readOnly && !destructive

  return {
    name: tool.name,
    description: tool.description ?? '',
    schema: DirectMCPArguments,
    jsonSchema: tool.inputSchema,
    ...(tool.outputSchema ? { outputSchema: tool.outputSchema } : {}),
    namespace: server.namespace,
    namespaceDescription: server.description,
    deferLoading: true,
    toolSearchText: [server.name, server.namespace, tool.name, tool.title, tool.description]
      .filter((value): value is string => typeof value === 'string' && value.length > 0)
      .join(' '),
    allowedCallers: ['direct', 'programmatic'],
    executionMode: parallel ? 'parallel' : 'sequential',
    isReadOnly: readOnly,
    isDestructive: destructive,
    describeActivity: () => `调用 MCP：${boundedString(`${server.name} / ${tool.name}`, 160)}`,
    async execute(_toolCallID, args, signal): Promise<AgentToolResult<unknown>> {
      const secrets = secretValues(server, options.workerEnv)
      const result = await callDirectMCPServerTool(server, tool.name, args, {
        workerEnv: options.workerEnv,
        signal: signal ?? options.abortSignal
      })
      if (result.isError === true) throw new Error(boundedError(mcpResultText(result), secrets))

      const structuredContent = validatedStructuredContent(tool, result, outputValidator)
      return await directMCPAgentResult(server, tool.name, result, structuredContent, options.artifactRoot, secrets)
    }
  }
}

function validatedStructuredContent(
  tool: DirectMCPListedTool,
  result: CallToolResult,
  outputValidator: OutputValidator | undefined
): unknown {
  if (!outputValidator) return result.structuredContent
  if (result.structuredContent === undefined) {
    throw new Error(`Direct MCP tool ${tool.name} declares an output schema but returned no structured content`)
  }
  const validation = outputValidator(result.structuredContent)
  if (!validation.valid) {
    throw new Error(`Direct MCP tool ${tool.name} returned content that does not match its output schema`)
  }
  return validation.data
}

async function directMCPAgentResult(
  server: DirectStdioMCPServer,
  toolName: string,
  result: CallToolResult,
  structuredContent: unknown,
  artifactRoot: string,
  secrets: string[]
): Promise<AgentToolResult<unknown>> {
  const textParts: string[] = []
  const images: ContentPart[] = []
  const artifactPaths: string[] = []

  for (const part of result.content.slice(0, 64)) {
    if (part.type === 'image') {
      const bytes = decodedImage(part.data, part.mimeType)
      const path = await writeArtifact(artifactRoot, imageExtension(part.mimeType), bytes)
      artifactPaths.push(path)
      images.push({ type: 'image', image: bytes, mimeType: part.mimeType })
      continue
    }

    if (part.type === 'text') {
      const text = redactSecrets(sanitizeBinaryOutput(part.text), secrets)
      if (server.name === 'flint-chart' && toolName === 'render_chart' && text.trimStart().startsWith('<svg')) {
        artifactPaths.push(await writeArtifact(artifactRoot, '.svg', `${text}\n`))
        continue
      }
      if (server.name === 'flint-chart' && toolName === 'compile_chart') {
        const spec = flintVegaLiteSpec(text)
        if (spec) artifactPaths.push(await writeArtifact(artifactRoot, '.vl.json', spec))
      }
      textParts.push(text)
      continue
    }

    textParts.push(redactSecrets(sanitizeBinaryOutput(JSON.stringify(part)), secrets))
  }

  const artifactText = artifactPaths.map(path => `Artifact path: ${path}`)
  const text = boundedString([...artifactText, ...textParts].filter(Boolean).join('\n'), maxResultTextBytes)
  const content: ContentPart[] = [...(text ? [{ type: 'text' as const, text }] : []), ...images]
  if (content.length === 0) content.push({ type: 'text', text: 'Direct MCP tool completed without content.' })

  return {
    content,
    details: {
      server: server.name,
      tool: toolName,
      artifacts: artifactPaths,
      structuredContent: boundedResultValue(structuredContent, secrets)
    }
  }
}

async function writeArtifact(root: string, extension: string, data: string | Uint8Array): Promise<string> {
  await mkdir(root, { recursive: true, mode: 0o700 })
  const stat = await lstat(root)
  if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error('Direct MCP artifact root must be a real directory')

  const path = join(root, `flint-chart-${randomUUID()}${extension}`)
  await writeFile(path, data, { flag: 'wx', mode: 0o600 })
  return path
}

function decodedImage(data: string, mimeType: string): Uint8Array {
  const normalized = data.replaceAll(/\s/g, '')
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(normalized) || normalized.length % 4 !== 0) {
    throw new Error('Direct MCP tool returned invalid base64 image data')
  }
  const bytes = Buffer.from(normalized, 'base64')
  if (bytes.byteLength === 0 || bytes.byteLength > VISION_MAX_INPUT_IMAGE_BYTES) {
    throw new Error(`Direct MCP image must contain 1 to ${VISION_MAX_INPUT_IMAGE_BYTES} bytes`)
  }
  if (mimeType === 'image/png' && !Buffer.from(bytes.subarray(0, 8)).equals(Buffer.from('89504e470d0a1a0a', 'hex'))) {
    throw new Error('Direct MCP tool returned invalid PNG data')
  }
  return bytes
}

function imageExtension(mimeType: string): string {
  if (mimeType === 'image/png') return '.png'
  if (mimeType === 'image/jpeg') return '.jpg'
  if (mimeType === 'image/webp') return '.webp'
  if (mimeType === 'image/gif') return '.gif'
  throw new Error(`Direct MCP tool returned unsupported image type ${mimeType}`)
}

function mcpResultText(result: CallToolResult): string {
  return (
    result.content
      .flatMap(part => (part.type === 'text' ? [part.text] : []))
      .join('\n')
      .trim() || 'MCP server returned an error'
  )
}

function toolIsModelVisible(tool: DirectMCPListedTool): boolean {
  const meta = recordValue(tool._meta)
  const ui = recordValue(meta.ui)
  if (!Array.isArray(ui.visibility)) return true
  return ui.visibility.includes('model')
}

function assertCallableName(value: string, label: string): void {
  if (!/^[A-Za-z0-9_]+$/.test(value)) throw new Error(`${label} contains unsupported characters: ${value}`)
}

function catalogCacheKey(server: DirectStdioMCPServer): string {
  return JSON.stringify({
    name: server.name,
    namespace: server.namespace,
    command: server.command,
    args: server.args,
    cwd: server.cwd,
    enabledTools: [...server.enabledTools].sort()
  })
}

function secretValues(server: DirectStdioMCPServer, workerEnv?: Record<string, string>): string[] {
  return [
    ...new Set((server.environmentVariables ?? []).map(name => workerEnv?.[name]).filter(Boolean) as string[])
  ].sort((left, right) => right.length - left.length)
}

function containsSecret(value: unknown, secrets: string[]): boolean {
  if (typeof value === 'string') return secrets.some(secret => value.includes(secret))
  if (Array.isArray(value)) return value.some(entry => containsSecret(entry, secrets))
  if (!value || typeof value !== 'object') return false
  return Object.entries(value as Record<string, unknown>).some(
    ([key, entry]) => containsSecret(key, secrets) || containsSecret(entry, secrets)
  )
}

function boundedResultValue(value: unknown, secrets: string[], depth = 0): unknown {
  if (depth >= maxValueDepth) return '[depth limit]'
  if (typeof value === 'string') {
    return boundedString(redactSecrets(sanitizeBinaryOutput(value), secrets), maxStringBytes)
  }
  if (value === null || typeof value === 'number' || typeof value === 'boolean') return value
  if (typeof value === 'bigint') return value.toString()
  if (value === undefined) return null
  if (Array.isArray(value)) {
    const entries = value.slice(0, maxArrayEntries).map(entry => boundedResultValue(entry, secrets, depth + 1))
    if (value.length > maxArrayEntries) entries.push(`[${value.length - maxArrayEntries} entries omitted]`)
    return entries
  }
  if (typeof value === 'object') {
    const output = Object.create(null) as Record<string, unknown>
    const entries = Object.entries(value as Record<string, unknown>)
    for (const [key, entry] of entries.slice(0, maxObjectEntries)) {
      output[boundedString(redactSecrets(sanitizeBinaryOutput(key), secrets), 512)] = boundedResultValue(
        entry,
        secrets,
        depth + 1
      )
    }
    if (entries.length > maxObjectEntries) output._ankole_omitted_entries = entries.length - maxObjectEntries
    return output
  }
  return boundedString(String(value), maxStringBytes)
}

function boundedError(error: unknown, secrets: string[]): string {
  const message = error instanceof Error ? error.message : String(error)
  return boundedString(redactSecrets(sanitizeBinaryOutput(message), secrets), maxErrorBytes)
}

function boundedString(value: string, maxBytes: number): string {
  if (utf8ByteLength(value) <= maxBytes) return value
  const suffix = '...[truncated]'
  return `${truncateUTF8Safe(value, maxBytes - utf8ByteLength(suffix))}${suffix}`
}

function redactSecrets(value: string, secrets: string[]): string {
  let redacted = value
  for (const secret of secrets) redacted = redacted.replaceAll(secret, '[REDACTED]')
  return redacted
}

function flintVegaLiteSpec(value: string): string | undefined {
  try {
    const compiled = recordValue(JSON.parse(value))
    const spec = recordValue(compiled.spec)
    if (compiled.backend !== 'vegalite' || Object.keys(spec).length === 0) return undefined
    return `${JSON.stringify(spec, null, 2)}\n`
  } catch {
    return undefined
  }
}

function recordValue(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : {}
}
