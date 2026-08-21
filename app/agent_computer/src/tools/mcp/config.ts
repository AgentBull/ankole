import { readFile, realpath } from 'node:fs/promises'
import { resolve } from 'node:path'
import { YAML } from 'bun'
import { z } from 'zod'
import type { RuntimeSkillSummary } from '../../lanes/rpc_lane'
import {
  normalizeEnabledSkill,
  resolveSkillFilesystemRoot,
  skillAvailableInRuntime,
  type AnkoleSkillExecutionRuntime,
  type SkillFileRoots
} from '../../skills/effective-skill'
import { utf8ByteLength } from '../../common/text-sanitize'
import { compareCodePointStrings } from '../../common/ordering'
import { errorMessage } from '../../common/errors'

const MAX_METADATA_BYTES = 64 * 1024
const MAX_ENABLED_SKILLS = 128
const MAX_ENABLED_SERVERS = 32
const MAX_DEPENDENCIES_PER_SKILL = 64
const MAX_FILTERED_TOOLS_PER_SERVER = 256
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
const ToolFilter = z.array(z.string().min(1).max(1024)).max(MAX_FILTERED_TOOLS_PER_SERVER)
const MCPProtocolVersion = z.enum(['auto', 'legacy', '2026-07-28'])
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
    protocol_version: MCPProtocolVersion.optional(),
    bearer_token_env_var: EnvironmentVariableName.optional(),
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
  enabledTools?: string[]
  disabledTools?: string[]
  sourceSkills: string[]
}

export interface StreamableHTTPMCPServer extends MCPServerBase {
  transport: 'streamable_http'
  url: string
  protocolVersion?: z.infer<typeof MCPProtocolVersion>
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
  runtime?: AnkoleSkillExecutionRuntime
}

/**
 * Loads the MCP declarations owned by enabled, inline Skills.
 *
 * `agents/openai.yaml` is the only accepted registration source. When the
 * caller selects a runtime, Skills for other runtimes are excluded before any
 * metadata file is read.
 */
export async function loadEnabledSkillMCPServers(input: LoadEnabledSkillMCPServersInput): Promise<MCPServerConfig[]> {
  const skills = input.enabledSkills
    .map(normalizeEnabledSkill)
    .filter((skill): skill is RuntimeSkillSummary => skill !== undefined)
    .filter(skill => input.runtime === undefined || skillAvailableInRuntime(skill, input.runtime))
    .sort((left, right) => compareCodePointStrings(left.skillName, right.skillName))

  assertMCPResourceLimit('aggregate enabled Skills', skills.length, MAX_ENABLED_SKILLS)

  if (skills.length === 0) return []
  if (!input.skillRoots) {
    throw new Error('enabled inline Skills require worker skill source roots for MCP dependency resolution')
  }

  const declarations = await Promise.all(
    skills.map(async skill => {
      const skillRoot = resolveSkillFilesystemRoot(skill, { skillRoots: input.skillRoots! })
      return await readSkillMCPDependencies(skill.skillName, skillRoot)
    })
  )

  const servers = new Map<string, MCPServerConfig>()
  for (const { skillName, dependencies } of declarations) {
    for (const dependency of dependencies) {
      const candidate = serverConfigFromDependency(skillName, dependency)
      const existing = servers.get(candidate.name)
      if (!existing) {
        assertMCPResourceLimit('aggregate enabled servers', servers.size + 1, MAX_ENABLED_SERVERS)
        servers.set(candidate.name, candidate)
        continue
      }

      if (serverConnectionIdentity(existing) !== serverConnectionIdentity(candidate)) {
        throw new Error(
          `conflicting MCP server declaration "${candidate.name}" in enabled Skills ${[...existing.sourceSkills, skillName].join(', ')}`
        )
      }

      existing.sourceSkills = [...new Set([...existing.sourceSkills, skillName])].sort(compareCodePointStrings)
    }
  }

  return [...servers.values()].sort((left, right) => compareCodePointStrings(left.name, right.name))
}

function assertMCPResourceLimit(subject: string, actual: number, limit: number): void {
  if (actual > limit) throw new Error(`MCP ${subject} exceeds the ${limit}-count limit`)
}

async function readSkillMCPDependencies(
  skillName: string,
  skillRoot: string
): Promise<{ skillName: string; dependencies: ParsedMCPDependency[] }> {
  const metadataPath = resolve(skillRoot, 'agents/openai.yaml')
  let content: string
  try {
    content = await readFile(metadataPath, 'utf8')
  } catch (error) {
    if (isMissingFileError(error)) return { skillName, dependencies: [] }
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
    raw = YAML.parse(content)
  } catch (error) {
    throw new Error(`invalid agents/openai.yaml for Skill ${skillName}: ${errorMessage(error)}`)
  }

  const parsed = OpenAIMetadata.safeParse(raw)
  if (!parsed.success) {
    const issue = parsed.error.issues[0]
    const location = issue?.path.length ? ` at ${issue.path.join('.')}` : ''
    throw new Error(`invalid MCP dependency for Skill ${skillName}${location}: ${issue?.message ?? 'invalid metadata'}`)
  }

  return { skillName, dependencies: parsed.data.dependencies?.tools ?? [] }
}

function serverConfigFromDependency(skillName: string, dependency: ParsedMCPDependency): MCPServerConfig {
  if (dependency.transport === 'streamable_http') {
    return {
      name: dependency.value,
      ...(dependency.description ? { description: dependency.description } : {}),
      transport: dependency.transport,
      url: dependency.url,
      ...(dependency.protocol_version ? { protocolVersion: dependency.protocol_version } : {}),
      ...(dependency.bearer_token_env_var ? { bearerTokenEnvVar: dependency.bearer_token_env_var } : {}),
      ...(dependency.enabled_tools ? { enabledTools: dependency.enabled_tools } : {}),
      ...(dependency.disabled_tools ? { disabledTools: dependency.disabled_tools } : {}),
      sourceSkills: [skillName]
    }
  }

  return {
    name: dependency.value,
    ...(dependency.description ? { description: dependency.description } : {}),
    transport: dependency.transport,
    command: dependency.command,
    ...(dependency.enabled_tools ? { enabledTools: dependency.enabled_tools } : {}),
    ...(dependency.disabled_tools ? { disabledTools: dependency.disabled_tools } : {}),
    sourceSkills: [skillName]
  }
}

/** Stable non-secret connection identity used for declaration conflicts. */
function serverConnectionIdentity(server: MCPServerConfig): string {
  return JSON.stringify(
    server.transport === 'streamable_http'
      ? {
          name: server.name,
          description: server.description ?? null,
          transport: server.transport,
          url: server.url,
          protocolVersion: server.protocolVersion ?? null,
          bearerTokenEnvVar: server.bearerTokenEnvVar ?? null,
          enabledTools: normalizedToolFilter(server.enabledTools),
          disabledTools: normalizedToolFilter(server.disabledTools)
        }
      : {
          name: server.name,
          description: server.description ?? null,
          transport: server.transport,
          command: server.command,
          enabledTools: normalizedToolFilter(server.enabledTools),
          disabledTools: normalizedToolFilter(server.disabledTools)
        }
  )
}

function normalizedToolFilter(tools: string[] | undefined): string[] | null {
  return tools ? [...new Set(tools)].sort(compareCodePointStrings) : null
}

function isMissingFileError(error: unknown): boolean {
  return error instanceof Error && 'code' in error && error.code === 'ENOENT'
}
