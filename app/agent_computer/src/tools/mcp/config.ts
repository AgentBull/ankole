import { readFile, realpath } from 'node:fs/promises'
import { resolve } from 'node:path'
import { createHash } from 'node:crypto'
import { parse } from 'yaml'
import { z } from 'zod'
import type { ActorTurnRef } from '../../lanes/actor_lane'
import type { RuntimeSkillSummary } from '../../lanes/rpc_lane'
import {
  normalizeEnabledSkill,
  resolveSkillFilesystemRoot,
  skillAvailableInRuntime,
  type AnkoleSkillExecutionRuntime,
  type SkillFileRoots
} from '../../skills/effective-skill'
import { utf8ByteLength } from '../../common/text-sanitize'
import { compareCodePointStrings } from './ordering'

const MAX_METADATA_BYTES = 64 * 1024
const MAX_DEPENDENCIES_PER_SKILL = 64
const MAX_FILTERED_TOOLS_PER_SERVER = 256
export const DEFAULT_MCP_TIMEOUT_MS = 360_000
export const MINIMUM_MCP_TIMEOUT_MS = 100
const ServerName = z
  .string()
  .trim()
  .min(1)
  .max(1024)
  .refine(value => !/[\p{Cc}\p{Cf}]/u.test(value), {
    message: 'server name must not contain control characters'
  })
const Description = z.string().trim().min(1).max(1024)
const EnvironmentVariableName = z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/)
const TimeoutMilliseconds = z.number().int().min(MINIMUM_MCP_TIMEOUT_MS).max(Number.MAX_SAFE_INTEGER)
const ToolFilter = z.array(z.string().min(1).max(1024)).max(MAX_FILTERED_TOOLS_PER_SERVER)
const HTTPURL = z
  .string()
  .url()
  .refine(value => ['http:', 'https:'].includes(new URL(value).protocol), 'URL must use HTTP or HTTPS')

const StreamableHTTPDependency = z
  .object({
    type: z.literal('mcp'),
    value: ServerName,
    description: Description.optional(),
    transport: z.literal('streamable_http'),
    url: HTTPURL,
    command: z.never().optional(),
    bearer_token_env_var: EnvironmentVariableName.optional(),
    timeout_ms: TimeoutMilliseconds.optional(),
    enabled_tools: ToolFilter.optional(),
    disabled_tools: ToolFilter.optional()
  })
  .strict()

const StdioDependency = z
  .object({
    type: z.literal('mcp'),
    value: ServerName,
    description: Description.optional(),
    transport: z.literal('stdio'),
    command: z.string().trim().min(1).max(1024),
    url: z.never().optional(),
    bearer_token_env_var: z.never().optional(),
    timeout_ms: TimeoutMilliseconds.optional(),
    enabled_tools: ToolFilter.optional(),
    disabled_tools: ToolFilter.optional()
  })
  .strict()

const MCPDependency = z.discriminatedUnion('transport', [StreamableHTTPDependency, StdioDependency])
const OpenAIMetadata = z
  .object({
    dependencies: z
      .object({
        tools: z.array(MCPDependency).max(MAX_DEPENDENCIES_PER_SKILL).default([])
      })
      .passthrough()
      .optional()
  })
  .passthrough()

type ParsedMCPDependency = z.output<typeof MCPDependency>

interface MCPServerBase {
  name: string
  description?: string
  timeoutMs?: number
  enabledTools?: string[]
  disabledTools?: string[]
  sourceSkills: string[]
  /** Hash of the actual enabled Skill metadata files contributing this declaration. */
  generation: string
}

export interface StreamableHTTPMCPServer extends MCPServerBase {
  transport: 'streamable_http'
  url: string
  bearerTokenEnvVar?: string
}

export interface StdioMCPServer extends MCPServerBase {
  transport: 'stdio'
  command: string
}

export type MCPServerConfig = StreamableHTTPMCPServer | StdioMCPServer

export interface LoadEnabledSkillMCPServersInput {
  enabledSkills: Array<RuntimeSkillSummary | string>
  skillRoots?: SkillFileRoots
  turn?: ActorTurnRef
  runtime?: AnkoleSkillExecutionRuntime
}

/**
 * Loads the MCP declarations owned by enabled, inline Skills.
 *
 * `agents/openai.yaml` is the only accepted registration source. Skills for a
 * different Ankole runtime are excluded before any metadata file is read.
 */
export async function loadEnabledSkillMCPServers(input: LoadEnabledSkillMCPServersInput): Promise<MCPServerConfig[]> {
  const runtime = input.runtime ?? 'main'
  const skills = input.enabledSkills
    .map(normalizeEnabledSkill)
    .filter((skill): skill is RuntimeSkillSummary => skill !== undefined)
    .filter(skill => skillAvailableInRuntime(skill, runtime))
    .sort((left, right) => compareCodePointStrings(left.skillName, right.skillName))

  if (skills.length === 0) return []
  if (!input.skillRoots) throw new Error('enabled inline Skills require worker skill source roots for MCP discovery')

  const declarations = await Promise.all(
    skills.map(async skill => {
      const skillRoot = resolveSkillFilesystemRoot(skill, { skillRoots: input.skillRoots!, turn: input.turn })
      return await readSkillMCPDependencies(skill.skillName, skillRoot)
    })
  )

  const servers = new Map<string, { server: MCPServerConfig; sourceGenerations: Map<string, string> }>()
  for (const { skillName, generation, dependencies } of declarations) {
    for (const dependency of dependencies) {
      const candidate = serverConfigFromDependency(skillName, dependency)
      const accumulated = servers.get(candidate.name)
      const existing = accumulated?.server
      if (!existing) {
        servers.set(candidate.name, { server: candidate, sourceGenerations: new Map([[skillName, generation]]) })
        continue
      }

      if (serverConnectionIdentity(existing) !== serverConnectionIdentity(candidate)) {
        throw new Error(
          `conflicting MCP server declaration "${candidate.name}" in enabled Skills ${[...existing.sourceSkills, skillName].join(', ')}`
        )
      }

      existing.sourceSkills = [...new Set([...existing.sourceSkills, skillName])].sort(compareCodePointStrings)
      accumulated.sourceGenerations.set(skillName, generation)
    }
  }

  return [...servers.values()]
    .map(({ server, sourceGenerations }) => ({
      ...server,
      generation: digest(
        [...sourceGenerations.entries()]
          .sort(([left], [right]) => compareCodePointStrings(left, right))
          .map(([skillName, generation]) => `${skillName}:${generation}`)
          .join('\n')
      )
    }))
    .sort((left, right) => compareCodePointStrings(left.name, right.name))
}

async function readSkillMCPDependencies(
  skillName: string,
  skillRoot: string
): Promise<{ skillName: string; generation: string; dependencies: ParsedMCPDependency[] }> {
  const metadataPath = resolve(skillRoot, 'agents/openai.yaml')
  let content: string
  try {
    content = await readFile(metadataPath, 'utf8')
  } catch (error) {
    if (isMissingFileError(error)) return { skillName, generation: digest('missing'), dependencies: [] }
    throw new Error(`failed to read MCP metadata for Skill ${skillName}: ${errorMessage(error)}`)
  }

  if (utf8ByteLength(content) > MAX_METADATA_BYTES) {
    throw new Error(`MCP metadata for Skill ${skillName} exceeds ${MAX_METADATA_BYTES} bytes`)
  }

  const [realSkillRoot, realMetadataPath] = await Promise.all([realpath(skillRoot), realpath(metadataPath)])
  if (realMetadataPath !== realSkillRoot && !realMetadataPath.startsWith(`${realSkillRoot}/`)) {
    throw new Error(`MCP metadata for Skill ${skillName} escapes its source directory`)
  }

  let raw: unknown
  try {
    raw = parse(content, { maxAliasCount: 20, strict: true, uniqueKeys: true })
  } catch (error) {
    throw new Error(`invalid agents/openai.yaml for Skill ${skillName}: ${errorMessage(error)}`)
  }

  const parsed = OpenAIMetadata.safeParse(raw)
  if (!parsed.success) {
    const issue = parsed.error.issues[0]
    const location = issue?.path.length ? ` at ${issue.path.join('.')}` : ''
    throw new Error(`invalid MCP dependency for Skill ${skillName}${location}: ${issue?.message ?? 'invalid metadata'}`)
  }

  return { skillName, generation: digest(content), dependencies: parsed.data.dependencies?.tools ?? [] }
}

function serverConfigFromDependency(skillName: string, dependency: ParsedMCPDependency): MCPServerConfig {
  if (dependency.transport === 'streamable_http') {
    return {
      name: dependency.value,
      ...(dependency.description ? { description: dependency.description } : {}),
      transport: dependency.transport,
      url: dependency.url,
      ...(dependency.bearer_token_env_var ? { bearerTokenEnvVar: dependency.bearer_token_env_var } : {}),
      ...(dependency.timeout_ms !== undefined ? { timeoutMs: dependency.timeout_ms } : {}),
      ...(dependency.enabled_tools ? { enabledTools: dependency.enabled_tools } : {}),
      ...(dependency.disabled_tools ? { disabledTools: dependency.disabled_tools } : {}),
      sourceSkills: [skillName],
      generation: ''
    }
  }

  return {
    name: dependency.value,
    ...(dependency.description ? { description: dependency.description } : {}),
    transport: dependency.transport,
    command: dependency.command,
    ...(dependency.timeout_ms !== undefined ? { timeoutMs: dependency.timeout_ms } : {}),
    ...(dependency.enabled_tools ? { enabledTools: dependency.enabled_tools } : {}),
    ...(dependency.disabled_tools ? { disabledTools: dependency.disabled_tools } : {}),
    sourceSkills: [skillName],
    generation: ''
  }
}

/** Stable non-secret connection identity used for conflict and cache keys. */
export function mcpServerConnectionIdentity(server: MCPServerConfig): string {
  return JSON.stringify(
    server.transport === 'streamable_http'
      ? {
          name: server.name,
          description: server.description ?? null,
          transport: server.transport,
          url: server.url,
          bearerTokenEnvVar: server.bearerTokenEnvVar ?? null,
          timeoutMs: server.timeoutMs ?? null,
          enabledTools: normalizedToolFilter(server.enabledTools),
          disabledTools: normalizedToolFilter(server.disabledTools)
        }
      : {
          name: server.name,
          description: server.description ?? null,
          transport: server.transport,
          command: server.command,
          timeoutMs: server.timeoutMs ?? null,
          enabledTools: normalizedToolFilter(server.enabledTools),
          disabledTools: normalizedToolFilter(server.disabledTools)
        }
  )
}

function normalizedToolFilter(tools: string[] | undefined): string[] | null {
  return tools ? [...new Set(tools)].sort(compareCodePointStrings) : null
}

function serverConnectionIdentity(server: MCPServerConfig): string {
  return mcpServerConnectionIdentity(server)
}

function digest(value: string): string {
  return createHash('sha256').update(value).digest('hex')
}

function isMissingFileError(error: unknown): boolean {
  return error instanceof Error && 'code' in error && error.code === 'ENOENT'
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
