import { create } from '@bufbuild/protobuf'
import { afterEach, describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { jsonBytes } from '../src/fabric/envelope_proto'
import { RuntimeSkillSummarySchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import {
  loadEnabledSkillMCPServers,
  materializeMCPorterConfig,
  renderMCPorterConfig,
  type MCPServerConfig
} from '../src/tools/mcp'

describe('@ankole/agent-computer Skill MCPorter config', () => {
  const roots: string[] = []

  afterEach(() => {
    for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
  })

  it('renders one stable config without ambient imports or secret values', () => {
    const servers: MCPServerConfig[] = [
      {
        name: 'z-local',
        description: 'Local data',
        sourceSkills: ['local-skill'],
        transport: 'stdio',
        command: 'bun run ./server.ts',
        disabledTools: ['write', 'delete', 'write']
      },
      {
        name: 'a-remote',
        description: 'Remote data',
        sourceSkills: ['remote-skill'],
        transport: 'streamable_http',
        url: 'https://mcp.example.test/rpc',
        protocolVersion: '2026-07-28',
        bearerTokenEnvVar: 'REMOTE_MCP_TOKEN',
        enabledTools: ['quote', 'news', 'quote'],
        disabledTools: ['news']
      }
    ]
    const previous = process.env.REMOTE_MCP_TOKEN
    process.env.REMOTE_MCP_TOKEN = 'must-not-enter-config'

    try {
      const first = renderMCPorterConfig(servers)
      const second = renderMCPorterConfig([...servers].reverse())
      expect(second).toBe(first)
      expect(first).not.toContain('must-not-enter-config')
      expect(JSON.parse(first)).toEqual({
        mcpServers: {
          'a-remote': {
            description: 'Remote data',
            baseUrl: 'https://mcp.example.test/rpc',
            protocolVersion: '2026-07-28',
            bearerToken: '${REMOTE_MCP_TOKEN}',
            allowedTools: ['quote']
          },
          'z-local': {
            description: 'Local data',
            command: '/bin/sh',
            args: ['-lc', 'bun run ./server.ts'],
            blockedTools: ['delete', 'write']
          }
        },
        imports: []
      })
    } finally {
      if (previous === undefined) delete process.env.REMOTE_MCP_TOKEN
      else process.env.REMOTE_MCP_TOKEN = previous
    }
  })

  it('materializes unique 0600 files and cleans them idempotently', () => {
    const root = temporaryRoot('ankole-mcporter-config-')
    const first = materializeMCPorterConfig([], { directory: root })
    const second = materializeMCPorterConfig([], { directory: root })

    expect(first.path).not.toBe(second.path)
    expect(first.env).toEqual({ MCPORTER_CONFIG: first.path })
    expect(statSync(first.path).mode & 0o777).toBe(0o600)
    expect(readFileSync(first.path, 'utf8')).toBe('{\n  "mcpServers": {},\n  "imports": []\n}\n')

    first.cleanup()
    first.cleanup()
    second.cleanup()
    expect(existsSync(first.path)).toBe(false)
    expect(existsSync(second.path)).toBe(false)
  })

  it('loads installed Skill declarations without a turn and filters only when a runtime is selected', async () => {
    const root = temporaryRoot('ankole-mcporter-skills-')
    const builtinSkillsRoot = join(root, 'builtin')
    const agentInstalledSkillsRoot = join(root, 'installed')
    writeMetadata(
      builtinSkillsRoot,
      'background-data',
      'dependencies:\n  tools:\n    - type: mcp\n      value: shared-data\n      transport: streamable_http\n      url: https://mcp.example.test/rpc\n      protocol_version: 2026-07-28\n'
    )
    writeSkill(agentInstalledSkillsRoot, 'installed-data', 'installed-data', 'https://installed.example.test/rpc')

    const backgroundSkill = create(RuntimeSkillSummarySchema, {
      skillName: 'background-data',
      sourceKind: 'builtin',
      relativePath: 'background-data',
      metadataJson: jsonBytes({ 'ankole-runtime': 'background_job' })
    })
    const installedSkill = create(RuntimeSkillSummarySchema, {
      skillName: 'installed-data',
      sourceKind: 'installed',
      relativePath: 'installed-data'
    })
    const skillRoots = { builtinSkillsRoot, agentInstalledSkillsRoot }

    expect(
      await loadEnabledSkillMCPServers({
        enabledSkills: [backgroundSkill, installedSkill],
        skillRoots,
        runtime: 'main'
      })
    ).toEqual([expect.objectContaining({ name: 'installed-data', sourceSkills: ['installed-data'] })])
    expect(await loadEnabledSkillMCPServers({ enabledSkills: [backgroundSkill, installedSkill], skillRoots })).toEqual([
      expect.objectContaining({ name: 'installed-data' }),
      expect.objectContaining({ name: 'shared-data', protocolVersion: '2026-07-28' })
    ])
  })

  it('merges identical declarations and rejects conflicting declarations', async () => {
    const root = temporaryRoot('ankole-mcporter-merge-')
    const builtinSkillsRoot = join(root, 'builtin')
    const agentInstalledSkillsRoot = join(root, 'installed')
    writeSkill(builtinSkillsRoot, 'one', 'shared', 'https://mcp.example.test/rpc')
    writeSkill(builtinSkillsRoot, 'two', 'shared', 'https://mcp.example.test/rpc')
    const skillRoots = { builtinSkillsRoot, agentInstalledSkillsRoot }
    const enabledSkills = ['one', 'two'].map(skillName =>
      create(RuntimeSkillSummarySchema, { skillName, sourceKind: 'builtin', relativePath: skillName })
    )

    expect(await loadEnabledSkillMCPServers({ enabledSkills, skillRoots, runtime: 'main' })).toEqual([
      expect.objectContaining({ name: 'shared', sourceSkills: ['one', 'two'] })
    ])

    writeSkill(builtinSkillsRoot, 'two', 'shared', 'https://other.example.test/rpc')
    await expect(loadEnabledSkillMCPServers({ enabledSkills, skillRoots, runtime: 'main' })).rejects.toThrow(
      'conflicting MCP server declaration "shared"'
    )
  })

  it('keeps declaration limits and rejects obsolete or unsupported fields', async () => {
    const tooManySkills = Array.from({ length: 129 }, (_, index) =>
      create(RuntimeSkillSummarySchema, {
        skillName: `skill-${index}`,
        sourceKind: 'builtin',
        relativePath: `skill-${index}`
      })
    )
    await expect(loadEnabledSkillMCPServers({ enabledSkills: tooManySkills })).rejects.toThrow(
      'MCP aggregate enabled Skills exceeds the 128-count limit'
    )

    const root = temporaryRoot('ankole-mcporter-limits-')
    const builtinSkillsRoot = join(root, 'builtin')
    const agentInstalledSkillsRoot = join(root, 'installed')
    const manyServers = [
      'dependencies:',
      '  tools:',
      ...Array.from({ length: 33 }, (_, index) => [
        '    - type: mcp',
        `      value: server-${index}`,
        '      transport: streamable_http',
        `      url: https://server-${index}.example.test/rpc`
      ]).flat()
    ].join('\n')
    writeMetadata(builtinSkillsRoot, 'too-many-servers', manyServers)
    const skillRoots = { builtinSkillsRoot, agentInstalledSkillsRoot }

    await expect(
      loadEnabledSkillMCPServers({
        enabledSkills: [
          create(RuntimeSkillSummarySchema, {
            skillName: 'too-many-servers',
            sourceKind: 'builtin',
            relativePath: 'too-many-servers'
          })
        ],
        skillRoots
      })
    ).rejects.toThrow('MCP aggregate enabled servers exceeds the 32-count limit')

    writeMetadata(
      builtinSkillsRoot,
      'obsolete-timeout',
      'dependencies:\n  tools:\n    - type: mcp\n      value: old\n      transport: streamable_http\n      url: https://old.example.test/rpc\n      timeout_ms: 1000\n'
    )
    await expect(
      loadEnabledSkillMCPServers({
        enabledSkills: [
          create(RuntimeSkillSummarySchema, {
            skillName: 'obsolete-timeout',
            sourceKind: 'builtin',
            relativePath: 'obsolete-timeout'
          })
        ],
        skillRoots
      })
    ).rejects.toThrow('invalid MCP dependency for Skill obsolete-timeout')

    writeMetadata(
      builtinSkillsRoot,
      'unknown-protocol',
      'dependencies:\n  tools:\n    - type: mcp\n      value: modern\n      transport: streamable_http\n      url: https://modern.example.test/rpc\n      protocol_version: 2027-01-01\n'
    )
    await expect(
      loadEnabledSkillMCPServers({
        enabledSkills: [
          create(RuntimeSkillSummarySchema, {
            skillName: 'unknown-protocol',
            sourceKind: 'builtin',
            relativePath: 'unknown-protocol'
          })
        ],
        skillRoots
      })
    ).rejects.toThrow('invalid MCP dependency for Skill unknown-protocol')
  })

  it('resolves internal Skills and rejects metadata symlinks outside the Skill root', async () => {
    const root = temporaryRoot('ankole-mcporter-paths-')
    const builtinSkillsRoot = join(root, 'builtin')
    const internalSkillsRoot = join(root, 'internal')
    const agentInstalledSkillsRoot = join(root, 'installed')
    writeSkill(internalSkillsRoot, 'internal-data', 'internal-data', 'https://internal.example.test/rpc')
    const internalSkill = create(RuntimeSkillSummarySchema, {
      skillName: 'internal-data',
      sourceKind: 'builtin',
      relativePath: 'internal-data',
      skillRoot: 'internal'
    })
    const skillRoots = { builtinSkillsRoot, internalSkillsRoot, agentInstalledSkillsRoot }

    expect(await loadEnabledSkillMCPServers({ enabledSkills: [internalSkill], skillRoots })).toEqual([
      expect.objectContaining({ name: 'internal-data', url: 'https://internal.example.test/rpc' })
    ])

    const escapedSkillRoot = join(builtinSkillsRoot, 'escaped')
    const escapedAgentsRoot = join(escapedSkillRoot, 'agents')
    const outsideMetadata = join(root, 'outside-openai.yaml')
    mkdirSync(escapedAgentsRoot, { recursive: true })
    writeFileSync(
      outsideMetadata,
      'dependencies:\n  tools:\n    - type: mcp\n      value: escaped\n      transport: streamable_http\n      url: https://escaped.example.test/rpc\n'
    )
    symlinkSync(outsideMetadata, join(escapedAgentsRoot, 'openai.yaml'))

    await expect(
      loadEnabledSkillMCPServers({
        enabledSkills: [
          create(RuntimeSkillSummarySchema, {
            skillName: 'escaped',
            sourceKind: 'builtin',
            relativePath: 'escaped'
          })
        ],
        skillRoots
      })
    ).rejects.toThrow('MCP metadata for Skill escaped escapes its source directory')
  })

  function temporaryRoot(prefix: string): string {
    const root = mkdtempSync(join(tmpdir(), prefix))
    roots.push(root)
    return root
  }
})

function writeSkill(root: string, skillName: string, serverName: string, url: string): void {
  writeMetadata(
    root,
    skillName,
    `dependencies:\n  tools:\n    - type: mcp\n      value: ${serverName}\n      transport: streamable_http\n      url: ${url}\n`
  )
}

function writeMetadata(root: string, skillName: string, content: string): void {
  const agentsRoot = join(root, skillName, 'agents')
  mkdirSync(agentsRoot, { recursive: true })
  writeFileSync(join(agentsRoot, 'openai.yaml'), content)
}
