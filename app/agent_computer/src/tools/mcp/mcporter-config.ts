import { randomUUID } from 'node:crypto'
import { rmSync } from 'node:fs'
import { writeFileAtomicSync } from '../../common/atomic-write'
import { join } from 'node:path'
import { WORKER_SHARE_ROOT } from '../../core/agent-home-paths'
import type { MCPServerConfig } from './config'
import { compareCodePointStrings } from '../../common/ordering'

const MCPORTER_CONFIG_ENV = 'MCPORTER_CONFIG'

export type MaterializedMCPorterConfig = {
  path: string
  env: Record<string, string>
  updateGateway: (options: GatewayOptions) => void
  cleanup: () => void
}

type MCPorterServer = {
  description?: string
  baseUrl?: string
  protocolVersion?: 'auto' | 'legacy' | '2026-07-28'
  bearerToken?: string
  command?: string
  args?: string[]
  cwd?: string
  allowedTools?: string[]
  blockedTools?: string[]
}

export type MCPorterConfiguredServer = MCPServerConfig

/** Renders one deterministic config from Skill dependencies. */
type ConnectionChoice = { connection: string; label: string; accounts: string[] }
type GatewayOptions = {
  gatewayOrigin?: string
  gatewayToken?: string
  connections?: Record<string, ConnectionChoice[]>
}
export function renderMCPorterConfig(
  servers: readonly MCPorterConfiguredServer[],
  options: GatewayOptions = {}
): string {
  const mcpServers: Record<string, MCPorterServer> = {}

  const entries = servers.flatMap(server => {
    if (server.transport !== 'connector' || server.account) return [server]

    const choices = (options.connections?.[server.toolkit] ?? []).filter(
      choice => !server.connection || server.connection === choice.connection
    )
    return [
      server,
      ...choices.flatMap(choice => {
        const selected = {
          ...server,
          name: server.connection ? server.name : `${server.name}@${choice.connection}`,
          description: choice.label,
          connection: choice.connection
        }
        return [
          ...(server.connection ? [] : [selected]),
          ...choice.accounts.map(account => ({
            ...selected,
            name: `${selected.name}@${encodeURIComponent(account).replaceAll('.', '%2E')}`,
            description: `${choice.label} · application account ${account}`,
            account
          }))
        ]
      })
    ]
  })
  for (const server of [...entries].sort((left, right) => compareCodePointStrings(left.name, right.name))) {
    if (Object.hasOwn(mcpServers, server.name)) {
      throw new Error(`duplicate MCPorter server: ${server.name}`)
    }

    const filters = mcpToolFilters(server)
    mcpServers[server.name] =
      server.transport !== 'stdio'
        ? {
            ...(server.description ? { description: server.description } : {}),
            baseUrl: gatewayURL(server, options.gatewayOrigin),
            protocolVersion: '2026-07-28',
            bearerToken: options.gatewayToken ?? '${ANKOLE_MCP_TOKEN}',
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
  servers: readonly MCPorterConfiguredServer[],
  options: GatewayOptions & { directory?: string } = {}
): MaterializedMCPorterConfig {
  const path = join(options.directory ?? WORKER_SHARE_ROOT, `ankole-mcporter-${randomUUID()}.json`)
  const contextPath = `${path}.context`
  const updateGateway = (gateway: GatewayOptions) => {
    writeFileAtomicSync(path, renderMCPorterConfig(servers, gateway), 0o600)
    if (gateway.gatewayToken) {
      writeFileAtomicSync(
        contextPath,
        JSON.stringify({ token: gateway.gatewayToken, origin: gateway.gatewayOrigin }),
        0o600
      )
    }
  }
  try {
    updateGateway(options)
  } catch (error) {
    rmSync(path, { force: true })
    rmSync(contextPath, { force: true })
    throw error
  }

  let cleaned = false
  return {
    path,
    env: { [MCPORTER_CONFIG_ENV]: path, ...(options.gatewayToken ? { ANKOLE_MCP_CONTEXT_FILE: contextPath } : {}) },
    updateGateway,
    cleanup: () => {
      if (cleaned) return
      cleaned = true
      rmSync(path, { force: true })
      rmSync(contextPath, { force: true })
    }
  }
}

function mcpToolFilters(server: MCPorterConfiguredServer): Pick<MCPorterServer, 'allowedTools' | 'blockedTools'> {
  const allowed = normalizedToolNames(server.enabledTools)
  const blocked = normalizedToolNames(server.disabledTools)

  if (allowed !== undefined) {
    const blockedNames = new Set(blocked ?? [])
    return { allowedTools: allowed.filter(name => !blockedNames.has(name)) }
  }
  return blocked === undefined ? {} : { blockedTools: blocked }
}

function normalizedToolNames(names: readonly string[] | undefined): string[] | undefined {
  return names === undefined ? undefined : [...new Set(names)].sort(compareCodePointStrings)
}

function gatewayURL(server: Exclude<MCPServerConfig, { transport: 'stdio' }>, origin?: string) {
  if (!origin) throw new Error('MCP HTTP calls require an active Turn gateway context')
  const path =
    server.transport === 'connector'
      ? `/api/internal/mcp/toolkits/${encodeURIComponent(server.toolkit)}`
      : `/api/internal/mcp/skills/${encodeURIComponent(server.sourceSkills[0]!)}/${encodeURIComponent(server.name)}`
  const url = new URL(path, origin)
  if (server.transport === 'connector') {
    if (server.connection) url.searchParams.set('connection', server.connection)
    if (server.account) url.searchParams.set('account', server.account)
  }
  return url.toString()
}
