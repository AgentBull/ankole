import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { RuntimeSkillSummarySchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { resolveCodexJobMCPServers } from '../src/core/codex-runner/mcp-config'

describe('@ankole/agent-computer Codex Job MCP config', () => {
  it('reuses agents/openai.yaml parsing and deduplicates the same non-secret connection', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-job-mcp-'))
    const libraryRoot = join(root, 'library')
    const standaloneRoot = join(libraryRoot, 'skills', 'standalone')
    const mainOnlyRoot = join(libraryRoot, 'skills', 'main-only')
    const pluginRoot = join(libraryRoot, 'agent-plugins', 'research')
    mkdirSync(join(standaloneRoot, 'agents'), { recursive: true })
    mkdirSync(join(mainOnlyRoot, 'agents'), { recursive: true })
    mkdirSync(join(pluginRoot, 'skills', 'research', 'agents'), { recursive: true })
    mkdirSync(join(pluginRoot, 'skills', 'disabled', 'agents'), { recursive: true })
    writeFileSync(join(standaloneRoot, 'SKILL.md'), '---\nname: standalone\ndescription: Standalone.\n---\n')
    writeFileSync(join(mainOnlyRoot, 'SKILL.md'), '---\nname: main-only\ndescription: Main only.\n---\n')
    writeFileSync(
      join(pluginRoot, 'skills', 'research', 'SKILL.md'),
      '---\nname: research\ndescription: Research.\n---\n'
    )
    const declaration = openAIYAML('https://mcp.example.test/rpc', 'MCP_ACCESS_TOKEN', 'external-data', 480_000)
    writeFileSync(join(standaloneRoot, 'agents', 'openai.yaml'), declaration)
    writeFileSync(
      join(mainOnlyRoot, 'agents', 'openai.yaml'),
      openAIYAML('https://main-only.example.test/rpc', undefined, 'main-only-server')
    )
    writeFileSync(join(pluginRoot, 'skills', 'research', 'agents', 'openai.yaml'), declaration)
    writeFileSync(
      join(pluginRoot, 'skills', 'disabled', 'agents', 'openai.yaml'),
      openAIYAML('https://disabled.example.test/rpc', undefined, 'disabled-server')
    )

    try {
      const servers = await resolveCodexJobMCPServers({
        enabledSkills: [
          create(RuntimeSkillSummarySchema, {
            skillName: 'standalone',
            sourceKind: 'builtin',
            relativePath: 'skills/standalone'
          }),
          create(RuntimeSkillSummarySchema, {
            skillName: 'research',
            sourceKind: 'builtin',
            agentPluginId: 'research',
            relativePath: 'agent-plugins/research/skills/research'
          }),
          create(RuntimeSkillSummarySchema, {
            skillName: 'main-only',
            sourceKind: 'builtin',
            relativePath: 'skills/main-only',
            metadataJson: new TextEncoder().encode(JSON.stringify({ 'ankole-runtime': 'main' }))
          })
        ],
        skillRoots: { builtinSkillsRoot: libraryRoot, agentInstalledSkillsRoot: join(root, 'installed') },
        turn: turn()
      })
      expect(servers).toHaveLength(1)
      expect(servers[0]).toEqual(
        expect.objectContaining({
          name: 'external-data',
          transport: 'streamable_http',
          url: 'https://mcp.example.test/rpc',
          bearerTokenEnvVar: 'MCP_ACCESS_TOKEN',
          timeoutMs: 480_000
        })
      )
      expect(JSON.stringify(servers)).not.toContain('secret-value')
      expect(JSON.stringify(servers)).not.toContain('disabled-server')
      expect(JSON.stringify(servers)).not.toContain('main-only-server')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('fails when standalone and Plugin Skills reuse a name with different endpoints', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-job-mcp-conflict-'))
    const libraryRoot = join(root, 'library')
    const standaloneRoot = join(libraryRoot, 'skills', 'standalone')
    const pluginRoot = join(libraryRoot, 'agent-plugins', 'research')
    mkdirSync(join(standaloneRoot, 'agents'), { recursive: true })
    mkdirSync(join(pluginRoot, 'skills', 'research', 'agents'), { recursive: true })
    writeFileSync(join(standaloneRoot, 'SKILL.md'), '# Standalone\n')
    writeFileSync(join(pluginRoot, 'skills', 'research', 'SKILL.md'), '# Research\n')
    writeFileSync(join(standaloneRoot, 'agents', 'openai.yaml'), openAIYAML('https://one.example.test/rpc'))
    writeFileSync(
      join(pluginRoot, 'skills', 'research', 'agents', 'openai.yaml'),
      openAIYAML('https://two.example.test/rpc')
    )

    try {
      await expect(
        resolveCodexJobMCPServers({
          enabledSkills: [
            create(RuntimeSkillSummarySchema, {
              skillName: 'standalone',
              sourceKind: 'builtin',
              relativePath: 'skills/standalone'
            }),
            create(RuntimeSkillSummarySchema, {
              skillName: 'research',
              sourceKind: 'builtin',
              agentPluginId: 'research',
              relativePath: 'agent-plugins/research/skills/research'
            })
          ],
          skillRoots: { builtinSkillsRoot: libraryRoot, agentInstalledSkillsRoot: join(root, 'installed') },
          turn: turn()
        })
      ).rejects.toThrow('conflicting MCP server declaration "external-data" in enabled Skills research, standalone')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function openAIYAML(url: string, bearerTokenEnvVar?: string, name = 'external-data', timeoutMs?: number): string {
  return [
    'dependencies:',
    '  tools:',
    '    - type: mcp',
    `      value: ${name}`,
    '      transport: streamable_http',
    `      url: ${url}`,
    ...(bearerTokenEnvVar ? [`      bearer_token_env_var: ${bearerTokenEnvVar}`] : []),
    ...(timeoutMs !== undefined ? [`      timeout_ms: ${timeoutMs}`] : [])
  ].join('\n')
}

function turn() {
  return {
    actor: { agent_uid: 'agent-1', session_id: 'job:job-1' },
    activation_uid: 'activation-1',
    actor_epoch: 1,
    actor_event_id: '00000000-0000-0000-0000-000000000001',
    revision: 0
  }
}
