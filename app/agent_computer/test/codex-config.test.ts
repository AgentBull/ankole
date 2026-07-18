import { describe, expect, it } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parse } from 'smol-toml'
import { materializeCodexConfig } from '../src/tools/codex/config'

describe('@ankole/agent-computer Codex config', () => {
  it('enables native collaboration for every BackgroundAgentJob by default', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-config-'))

    try {
      const materialized = materializeCodexConfig({
        sharedFsRoot: root,
        jobID: '00000000-0000-0000-0000-000000000001',
        runtime: {
          mode: 'official_subscription',
          accountID: 'account-1',
          authJSON: '{}',
          authHash: 'auth-hash'
        }
      })
      const config = parse(readFileSync(join(materialized.codexHome, 'config.toml'), 'utf8')) as Record<string, any>

      expect(config.features.multi_agent).toBe(false)
      expect(config.features.multi_agent_v2).toEqual({
        enabled: true,
        hide_spawn_agent_metadata: true
      })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
