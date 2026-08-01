import { randomUUID } from 'node:crypto'
import { chmodSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { WORKER_SHARE_ROOT } from '../../core/agent-home-paths'
import type { MCPServerConfig } from './config'
import type { DirectStdioMCPServer } from './direct-registry'
import { compareCodePointStrings } from './ordering'

export const MCPORTER_CONFIG_ENV = 'MCPORTER_CONFIG'

export type MaterializedMCPorterConfig = {
  path: string
  env: Record<typeof MCPORTER_CONFIG_ENV, string>
  cleanup: () => void
}

type MCPorterServer = {
  description?: string
  baseUrl?: string
  bearerTokenEnv?: string
  command?: string
  args?: string[]
  cwd?: string
  allowedTools?: string[]
  blockedTools?: string[]
}

export type MCPorterConfiguredServer = MCPServerConfig | DirectStdioMCPServer

/** Renders one deterministic config from Skill dependencies and Direct MCP servers. */
export function renderMCPorterConfig(servers: MCPorterConfiguredServer[]): string {
  const mcpServers: Record<string, MCPorterServer> = {}

  for (const server of [...servers].sort((left, right) => compareCodePointStrings(left.name, right.name))) {
    if (Object.hasOwn(mcpServers, server.name)) {
      throw new Error(`duplicate MCPorter server: ${server.name}`)
    }

    const filters = mcpToolFilters(server)
    mcpServers[server.name] =
      server.transport === 'streamable_http'
        ? {
            ...(server.description ? { description: server.description } : {}),
            baseUrl: server.url,
            ...(server.bearerTokenEnvVar ? { bearerTokenEnv: server.bearerTokenEnvVar } : {}),
            ...filters
          }
        : 'namespace' in server
          ? {
              description: server.description,
              command: server.command,
              args: server.args,
              cwd: server.cwd,
              ...filters
            }
          : {
              ...(server.description ? { description: server.description } : {}),
              command: '/bin/sh',
              args: ['-lc', server.command],
              ...filters
            }
  }

  return `${JSON.stringify({ mcpServers, imports: [] }, null, 2)}\n`
}

/** Writes one invocation-scoped config that disables ambient MCP imports. */
export function materializeMCPorterConfig(
  servers: MCPorterConfiguredServer[],
  options: { directory?: string } = {}
): MaterializedMCPorterConfig {
  const path = join(options.directory ?? WORKER_SHARE_ROOT, `ankole-mcporter-${randomUUID()}.json`)
  try {
    writeFileSync(path, renderMCPorterConfig(servers), { flag: 'wx', mode: 0o600 })
    chmodSync(path, 0o600)
  } catch (error) {
    rmSync(path, { force: true })
    throw error
  }

  let cleaned = false
  return {
    path,
    env: { [MCPORTER_CONFIG_ENV]: path },
    cleanup: () => {
      if (cleaned) return
      cleaned = true
      rmSync(path, { force: true })
    }
  }
}

function mcpToolFilters(server: MCPorterConfiguredServer): Pick<MCPorterServer, 'allowedTools' | 'blockedTools'> {
  const allowed = normalizedToolNames(server.enabledTools)
  const blocked = normalizedToolNames('disabledTools' in server ? server.disabledTools : undefined)

  if (allowed !== undefined) {
    const blockedNames = new Set(blocked ?? [])
    return { allowedTools: allowed.filter(name => !blockedNames.has(name)) }
  }
  return blocked === undefined ? {} : { blockedTools: blocked }
}

function normalizedToolNames(names: string[] | undefined): string[] | undefined {
  return names === undefined ? undefined : [...new Set(names)].sort(compareCodePointStrings)
}
