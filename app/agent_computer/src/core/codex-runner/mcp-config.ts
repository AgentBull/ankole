import { genericHash } from '@ankole/kernel'
import type { ActorTurnRef } from '../../lanes/actor_lane'
import type { RuntimeSkillSummary } from '../../lanes/rpc_lane'
import type { SkillFileRoots } from '../../skills/effective-skill'
import { loadEnabledSkillMCPServers, mcpServerConnectionIdentity, type MCPServerConfig } from '../../tools/mcp/config'

/** Resolves standalone and Agent Plugin Skill MCP declarations through the ordinary Skill locator. */
export async function resolveCodexJobMCPServers(input: {
  enabledSkills: RuntimeSkillSummary[]
  skillRoots?: SkillFileRoots
  turn: ActorTurnRef
}): Promise<MCPServerConfig[]> {
  const servers = await loadEnabledSkillMCPServers({
    enabledSkills: input.enabledSkills,
    skillRoots: input.skillRoots,
    turn: input.turn,
    runtime: 'background_job'
  })
  return mergeMCPServers(servers)
}

function mergeMCPServers(servers: MCPServerConfig[]): MCPServerConfig[] {
  const merged = new Map<string, MCPServerConfig>()
  for (const candidate of servers) {
    const existing = merged.get(candidate.name)
    if (!existing) {
      merged.set(candidate.name, { ...candidate, sourceSkills: [...candidate.sourceSkills] })
      continue
    }
    if (mcpServerConnectionIdentity(existing) !== mcpServerConnectionIdentity(candidate)) {
      throw new Error(
        `conflicting MCP server declaration "${candidate.name}" across Job Skills ${[
          ...existing.sourceSkills,
          ...candidate.sourceSkills
        ].join(', ')}`
      )
    }
    existing.sourceSkills = [...new Set([...existing.sourceSkills, ...candidate.sourceSkills])].sort(compareCodePoints)
    existing.generation = genericHash(
      Buffer.from([existing.generation, candidate.generation].sort(compareCodePoints).join('\n'))
    )
  }
  return [...merged.values()].sort((left, right) => compareCodePoints(left.name, right.name))
}

function compareCodePoints(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}
