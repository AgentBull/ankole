import { describe, expect, it } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parse } from 'smol-toml'
import { codexConfigCLIOverrides, materializeCodexConfig } from '../src/tools/codex/config'

function officialRuntime(accountID: string) {
  return {
    mode: 'official_subscription' as const,
    accountID,
    authJSON: '{}',
    authHash: 'hash',
    modelProfile: { model: 'gpt-5.6-sol', modelReasoningEffort: 'high' as const, fastMode: false }
  }
}

describe('@ankole/agent-computer Codex config', () => {
  it('shares the official Codex Home at Agent scope without CODEX_SQLITE_HOME', () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-codex-config-'))
    try {
      const materialized = materializeCodexConfig({
        agentsRoot,
        agentUID: 'agent-1',
        runtime: officialRuntime('account-1')
      })
      const config = parse(readFileSync(join(materialized.codexHome, 'config.toml'), 'utf8')) as Record<string, any>
      expect(materialized.agentHome).toBe(join(agentsRoot, 'agent-1'))
      expect(materialized.codexHome).toBe(join(agentsRoot, 'agent-1', '.codex'))
      expect(materialized.env.HOME).toBe(materialized.agentHome)
      expect(materialized.env.CODEX_HOME).toBe(materialized.codexHome)
      expect(materialized.env.CODEX_SQLITE_HOME).toBeUndefined()
      expect(config.features.multi_agent_v2.enabled).toBe(true)

      const overlappingJob = materializeCodexConfig({
        agentsRoot,
        agentUID: 'agent-1',
        runtime: officialRuntime('account-1')
      })
      const anotherAgent = materializeCodexConfig({
        agentsRoot,
        agentUID: 'agent-2',
        runtime: officialRuntime('account-2')
      })

      expect(overlappingJob.codexHome).toBe(materialized.codexHome)
      expect(anotherAgent.codexHome).toBe(join(agentsRoot, 'agent-2', '.codex'))
      expect(anotherAgent.codexHome).not.toBe(materialized.codexHome)
    } finally {
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })

  it('trusts a project path through one TOML table override', () => {
    const projectRoot = '/agents/agent.v1/jobs/1000'
    const override = codexConfigCLIOverrides(projectRoot).at(-1)

    expect(override).toBeDefined()
    expect(parse(override!)).toEqual({ projects: { [projectRoot]: { trust_level: 'trusted' } } })
  })
})
