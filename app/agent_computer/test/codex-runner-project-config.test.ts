import { TOML } from 'bun'
import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { materializeCodexJobProjectConfig } from '../src/core/codex-runner/project-config'

describe('@ankole/agent-computer Codex job project config', () => {
  it('removes thread-owned settings from templates and applies runner safety', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-project-config-'))
    const configPath = join(root, '.codex', 'config.toml')
    mkdirSync(join(root, '.codex'), { recursive: true })
    writeFileSync(
      configPath,
      [
        'model = "plugin-model"',
        'model_catalog_json = "/plugin/models.json"',
        'model_reasoning_effort = "medium"',
        'service_tier = "priority"',
        'web_search = "live"',
        '',
        '[features.multi_agent_v2]',
        'enabled = false',
        'max_concurrent_threads_per_session = 99',
        'max_wait_timeout_ms = 999999',
        '',
        '[mcp_servers.stale-template-server]',
        'url = "https://stale.example.test/mcp"',
        ''
      ].join('\n')
    )

    try {
      const materialized = materializeCodexJobProjectConfig({
        projectRoot: root,
        hostedWebSearch: false
      })
      const config = TOML.parse(readFileSync(configPath, 'utf8')) as Record<string, any>

      expect(materialized).toEqual({ path: configPath })
      expect(config.model).toBeUndefined()
      expect(config.model_catalog_json).toBeUndefined()
      expect(config.model_provider).toBeUndefined()
      expect(config.service_tier).toBeUndefined()
      expect(config.model_reasoning_effort).toBeUndefined()
      expect(config.web_search).toBe('disabled')
      expect(config.features.memories).toBe(false)
      expect(config.features.plugins).toBe(false)
      expect(config.features.code_mode).toEqual({ enabled: true })
      expect(config.features.multi_agent_v2).toEqual({
        default_wait_timeout_ms: 120_000,
        enabled: true,
        hide_spawn_agent_metadata: true,
        max_concurrent_threads_per_session: 99,
        min_wait_timeout_ms: 60_000
      })
      expect(config.features.multi_agent_v2.max_wait_timeout_ms).toBeUndefined()
      expect(config.agents).toBeUndefined()
      expect(config.mcp_servers).toBeUndefined()
      expect(readFileSync(configPath, 'utf8')).not.toContain('secret-value')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('enables Codex web search only from the projected hosted-tool declaration', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-project-config-web-search-'))
    try {
      materializeCodexJobProjectConfig({
        projectRoot: root,
        hostedWebSearch: true
      })
      const config = TOML.parse(readFileSync(join(root, '.codex', 'config.toml'), 'utf8')) as Record<string, any>
      expect(config.web_search).toBe('live')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('fails closed on invalid template config', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-project-config-invalid-'))
    mkdirSync(join(root, '.codex'), { recursive: true })
    writeFileSync(join(root, '.codex', 'config.toml'), '[features\nplugins = true\n')
    try {
      expect(() =>
        materializeCodexJobProjectConfig({
          projectRoot: root,
          hostedWebSearch: false
        })
      ).toThrow('invalid Codex project config')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('materializes only project-owned policy without thread settings', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-project-config-default-'))
    try {
      materializeCodexJobProjectConfig({
        projectRoot: root,
        hostedWebSearch: false
      })
      const config = TOML.parse(readFileSync(join(root, '.codex', 'config.toml'), 'utf8')) as Record<string, any>
      expect(config.web_search).toBe('disabled')
      expect(config.features.plugins).toBe(false)
      expect(config.model).toBeUndefined()
      expect(config.model_provider).toBeUndefined()
      expect(config.features.multi_agent_v2).toEqual({
        default_wait_timeout_ms: 120_000,
        enabled: true,
        hide_spawn_agent_metadata: true,
        min_wait_timeout_ms: 60_000
      })
      expect(config.features.multi_agent_v2.max_wait_timeout_ms).toBeUndefined()
      expect(config.mcp_servers).toBeUndefined()
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
