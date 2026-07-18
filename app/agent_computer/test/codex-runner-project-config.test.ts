import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parse } from 'smol-toml'
import { materializeCodexJobProjectConfig } from '../src/core/codex-runner/project-config'

describe('@ankole/agent-computer Codex job project config', () => {
  it('applies Job overrides and runner safety over the initialized project config', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-project-config-'))
    const configPath = join(root, '.codex', 'config.toml')
    mkdirSync(join(root, '.codex'), { recursive: true })
    writeFileSync(
      configPath,
      [
        'model = "plugin-model"',
        'model_reasoning_effort = "medium"',
        'web_search = "live"',
        '',
        '[features.multi_agent_v2]',
        'enabled = false',
        'max_concurrent_threads_per_session = 99',
        ''
      ].join('\n')
    )

    try {
      const materialized = materializeCodexJobProjectConfig({
        projectRoot: root,
        execution: { model: 'job-model', reasoningEffort: 'high' },
        pluginsEnabled: true,
        mcpServers: [
          {
            name: 'remote-data',
            generation: 'remote-generation',
            sourceSkills: ['research'],
            transport: 'streamable_http',
            url: 'https://mcp.example.test/rpc',
            bearerTokenEnvVar: 'REMOTE_DATA_TOKEN',
            timeoutMs: 480_000
          },
          {
            name: 'local-data',
            generation: 'local-generation',
            sourceSkills: ['research'],
            transport: 'stdio',
            command: 'bun run /repo/tools/local-mcp.ts'
          }
        ]
      })
      const config = parse(readFileSync(configPath, 'utf8')) as Record<string, any>

      expect(materialized).toEqual({
        path: configPath,
        model: 'job-model',
        threadConfig: { model_reasoning_effort: 'high' }
      })
      expect(config.model).toBe('job-model')
      expect(config.model_reasoning_effort).toBe('high')
      expect(config.web_search).toBe('disabled')
      expect(config.features.memories).toBe(false)
      expect(config.features.plugins).toBe(true)
      expect(config.features.multi_agent_v2).toEqual({
        enabled: true,
        hide_spawn_agent_metadata: true,
        max_concurrent_threads_per_session: 99
      })
      expect(config.agents).toBeUndefined()
      expect(config.mcp_servers).toEqual({
        'local-data': {
          command: '/bin/sh',
          args: ['-lc', 'bun run /repo/tools/local-mcp.ts'],
          tool_timeout_sec: 360
        },
        'remote-data': {
          url: 'https://mcp.example.test/rpc',
          bearer_token_env_var: 'REMOTE_DATA_TOKEN',
          tool_timeout_sec: 480
        }
      })
      expect(readFileSync(configPath, 'utf8')).not.toContain('secret-value')
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
          execution: {},
          pluginsEnabled: false,
          mcpServers: []
        })
      ).toThrow('invalid Codex project config')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('materializes the default config without any Job policy fields', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-project-config-default-'))
    try {
      materializeCodexJobProjectConfig({
        projectRoot: root,
        execution: {},
        pluginsEnabled: false,
        mcpServers: []
      })
      const config = parse(readFileSync(join(root, '.codex', 'config.toml'), 'utf8')) as Record<string, any>
      expect(config.features.plugins).toBe(false)
      expect(config.features.multi_agent_v2).toEqual({
        enabled: true,
        hide_spawn_agent_metadata: true
      })
      expect(config.mcp_servers).toBeUndefined()
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
