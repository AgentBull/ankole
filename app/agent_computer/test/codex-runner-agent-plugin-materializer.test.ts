import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { jsonBytes } from '../src/fabric/envelope_proto'
import {
  AgentPluginCatalogEntrySchema,
  RuntimeSkillSummarySchema,
  SkillOverlayResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parse } from 'smol-toml'
import {
  computeAgentPluginContentHash,
  assertAgentPluginProjectResumeState,
  installAndTrustAgentPlugins,
  materializeAgentPluginSkillOverlays,
  prepareAgentPlugins
} from '../src/core/codex-runner/agent-plugin-materializer'
import type { ActorTurnRef } from '../src/lanes/actor_lane'
import { rpcMethods, type AgentPluginCatalogEntry, type RPCRequester } from '../src/lanes/rpc_lane'

describe('@ankole/agent-computer Agent Plugin materializer', () => {
  it('validates identity, copies templates once, and never recopies them on resume', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-agent-plugin-materializer-'))
    const libraryRoot = join(root, 'library')
    const projectRoot = join(root, 'project')
    createPlugin(libraryRoot, 'alpha', {
      config: '[features]\nplugins = true\n',
      files: { 'AGENTS.md': 'alpha instructions\n' }
    })
    createPlugin(libraryRoot, 'beta', {
      files: { 'research/.keep': '' }
    })
    const catalog = agentPluginCatalog(libraryRoot, ['beta', 'alpha'])

    try {
      const first = prepareAgentPlugins({
        projectRoot,
        agentPlugins: catalog,
        libraryRoot,
        initializeProject: true,
        agentsContent: '# Job guidance'
      })
      expect(first.agentPlugins.map(plugin => plugin.id)).toEqual(['alpha', 'beta'])
      expect(first.expectedSkillNames).toEqual(['alpha:alpha-skill', 'beta:beta-skill'])
      expect(first.marketplacePath).toBe('/workspace/.agents/plugins/marketplace.json')
      expect(first.marketplaceHostPath).toBe(join(projectRoot, '.agents', 'plugins', 'marketplace.json'))
      expect(JSON.parse(readFileSync(first.marketplaceHostPath, 'utf8')).plugins).toEqual([
        expect.objectContaining({ name: 'alpha', source: { source: 'local', path: './plugins/alpha' } }),
        expect.objectContaining({ name: 'beta', source: { source: 'local', path: './plugins/beta' } })
      ])
      expect(parse(readFileSync(join(projectRoot, '.codex', 'config.toml'), 'utf8'))).toEqual({
        features: { plugins: true }
      })
      expect(readFileSync(join(projectRoot, 'research', '.keep'), 'utf8')).toBe('')
      expect(readFileSync(join(projectRoot, 'AGENTS.md'), 'utf8')).toBe('alpha instructions\n\n# Job guidance\n')

      writeFileSync(join(projectRoot, 'AGENTS.md'), 'job-local edit\n')
      const second = prepareAgentPlugins({
        projectRoot,
        agentPlugins: catalog,
        libraryRoot,
        initializeProject: false
      })
      expect(second.agentPlugins.map(plugin => plugin.id)).toEqual(['alpha', 'beta'])
      expect(readFileSync(join(projectRoot, 'AGENTS.md'), 'utf8')).toBe('job-local edit\n')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects first-initialization template conflicts and package symlinks', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-plugin-conflicts-'))
    const libraryRoot = join(root, 'library')
    createPlugin(libraryRoot, 'alpha', {
      config: '[features]\nplugins = true\n',
      files: { 'AGENTS.md': 'alpha\n' }
    })
    createPlugin(libraryRoot, 'file-conflict', { files: { 'AGENTS.md': 'other\n' } })
    createPlugin(libraryRoot, 'config-conflict', { config: '[features]\nplugins = false\n' })

    try {
      expect(() =>
        prepareAgentPlugins({
          projectRoot: join(root, 'file-project'),
          agentPlugins: agentPluginCatalog(libraryRoot, ['alpha', 'file-conflict']),
          libraryRoot,
          initializeProject: true,
          agentsContent: 'job guidance'
        })
      ).toThrow('workspace template file conflict at AGENTS.md')

      expect(() =>
        prepareAgentPlugins({
          projectRoot: join(root, 'config-project'),
          agentPlugins: agentPluginCatalog(libraryRoot, ['alpha', 'config-conflict']),
          libraryRoot,
          initializeProject: true,
          agentsContent: 'job guidance'
        })
      ).toThrow('workspace template file conflict at .codex/config.toml')

      const symlinkPlugin = join(libraryRoot, 'symlinked')
      createPlugin(libraryRoot, 'symlinked', {})
      symlinkSync(join(symlinkPlugin, '.codex-plugin', 'plugin.json'), join(symlinkPlugin, 'manifest-link'))
      expect(() => computeAgentPluginContentHash(symlinkPlugin)).toThrow('cannot contain symlinks')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rebuilds a partial pre-thread initialization without touching anything outside the private project', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-plugin-partial-init-'))
    const libraryRoot = join(root, 'library')
    const projectRoot = join(root, 'job', 'project')
    const external = join(root, 'caller-workspace.txt')
    createPlugin(libraryRoot, 'alpha', { files: { 'AGENTS.md': 'complete\n' } })
    mkdirSync(join(projectRoot, 'plugins', 'alpha'), { recursive: true })
    writeFileSync(join(projectRoot, 'plugins', 'alpha', 'partial'), 'partial')
    writeFileSync(join(projectRoot, 'AGENTS.md'), 'partial\n')
    writeFileSync(external, 'caller-owned\n')

    try {
      const prepared = prepareAgentPlugins({
        projectRoot,
        agentPlugins: agentPluginCatalog(libraryRoot, ['alpha']),
        libraryRoot,
        initializeProject: true,
        agentsContent: 'job guidance'
      })
      expect(readFileSync(join(projectRoot, 'AGENTS.md'), 'utf8')).toBe('complete\n\njob guidance\n')
      expect(
        readFileSync(join(prepared.agentPlugins[0]!.materializedRoot, '.codex-plugin', 'plugin.json'), 'utf8')
      ).toContain('"version":"1.0.0"')
      expect(readFileSync(external, 'utf8')).toBe('caller-owned\n')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('refreshes the current package on resume without reapplying its workspace template', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-plugin-current-resume-'))
    const libraryRoot = join(root, 'library')
    const projectRoot = join(root, 'project')
    createPlugin(libraryRoot, 'alpha', {})
    const initialCatalog = agentPluginCatalog(libraryRoot, ['alpha'])

    try {
      prepareAgentPlugins({
        projectRoot,
        agentPlugins: initialCatalog,
        libraryRoot,
        initializeProject: true,
        agentsContent: 'job guidance'
      })
      writeFileSync(join(projectRoot, 'AGENTS.md'), 'preserved project guidance\n')
      rmSync(join(libraryRoot, 'alpha'), { recursive: true, force: true })
      createPlugin(libraryRoot, 'alpha', { files: { 'v2.txt': 'new image bytes\n' } })
      const currentCatalog = agentPluginCatalog(libraryRoot, ['alpha'])

      const resumed = prepareAgentPlugins({
        projectRoot,
        agentPlugins: currentCatalog,
        libraryRoot,
        initializeProject: false
      })
      expect(resumed.agentPlugins[0]).toMatchObject({
        id: 'alpha',
        version: '1.0.0',
        contentHash: currentCatalog[0]!.contentHash
      })
      expect(
        readFileSync(join(resumed.agentPlugins[0]!.materializedRoot, 'workspace-template', 'v2.txt'), 'utf8')
      ).toBe('new image bytes\n')
      expect(readFileSync(join(projectRoot, 'AGENTS.md'), 'utf8')).toBe('preserved project guidance\n')
      expect(existsSync(join(projectRoot, 'v2.txt'))).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('fails closed when the private project is missing for a persisted thread', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-plugin-retained-project-'))
    const libraryRoot = join(root, 'library')
    const projectRoot = join(root, 'project')
    createPlugin(libraryRoot, 'alpha', {})
    try {
      prepareAgentPlugins({
        projectRoot,
        agentPlugins: agentPluginCatalog(libraryRoot, ['alpha']),
        libraryRoot,
        initializeProject: true,
        agentsContent: 'job guidance'
      })
      rmSync(projectRoot, { recursive: true, force: true })
      expect(() => assertAgentPluginProjectResumeState(projectRoot)).toThrow(
        'project is missing for a persisted runtime thread'
      )
      expect(existsSync(projectRoot)).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('enforces the control-plane package size limits before hashing content', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-plugin-limits-'))
    createPlugin(root, 'oversized', {})
    writeFileSync(join(root, 'oversized', 'too-large.bin'), Buffer.alloc(8 * 1024 * 1024 + 1))
    try {
      expect(() => computeAgentPluginContentHash(join(root, 'oversized'))).toThrow('file exceeds 8388608 bytes')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('loads member Skills from the directory declared by the standard Plugin manifest', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-plugin-manifest-skills-'))
    const libraryRoot = join(root, 'library')
    const projectRoot = join(root, 'project')
    createPlugin(libraryRoot, 'alpha', { skillsPath: 'capabilities/skills' })

    try {
      const prepared = prepareAgentPlugins({
        projectRoot,
        agentPlugins: agentPluginCatalog(libraryRoot, ['alpha']),
        libraryRoot,
        initializeProject: true,
        agentsContent: 'job guidance'
      })

      expect(prepared.agentPlugins[0]).toMatchObject({
        skillsRelativePath: 'capabilities/skills',
        memberSkillNames: ['alpha-skill'],
        enabledCodexSkillNames: ['alpha:alpha-skill']
      })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('applies a Plugin member Skill overlay only to the Job-local package copy', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-plugin-member-overlay-'))
    const libraryRoot = join(root, 'library')
    const projectRoot = join(root, 'project')
    createPlugin(libraryRoot, 'alpha', {})

    try {
      const prepared = prepareAgentPlugins({
        projectRoot,
        agentPlugins: agentPluginCatalog(libraryRoot, ['alpha']),
        libraryRoot,
        initializeProject: true,
        agentsContent: 'job guidance'
      })
      const sourceSkillPath = join(libraryRoot, 'alpha', 'skills', 'alpha-skill', 'SKILL.md')
      const sourceContent = readFileSync(sourceSkillPath, 'utf8')
      const memberSkill = create(RuntimeSkillSummarySchema, {
        skillName: 'alpha-skill',
        sourceKind: 'builtin',
        relativePath: 'agent-plugins/alpha/skills/alpha-skill',
        agentPluginId: 'alpha'
      })

      await materializeAgentPluginSkillOverlays({
        prepared,
        enabledSkills: [memberSkill],
        turn: turn(),
        rpc: (async (method: unknown, payload: unknown) => {
          expect(method).toBe(rpcMethods.skillsOverlayResolve)
          expect(payload).toEqual({ skillName: 'alpha-skill' })
          return create(SkillOverlayResponseSchema, {
            skillName: 'alpha-skill',
            hasOverlay: true,
            overlayJson: jsonBytes({ text: 'PLUGIN_OVERLAY_MARKER' }),
            contentHash: 'overlay-hash'
          })
        }) as RPCRequester
      })

      const materializedSkillPath = join(
        prepared.agentPlugins[0]!.materializedRoot,
        'skills',
        'alpha-skill',
        'SKILL.md'
      )
      const materializedContent = readFileSync(materializedSkillPath, 'utf8')
      expect(materializedContent).toContain('Agent-specific additions:')
      expect(materializedContent).toContain('PLUGIN_OVERLAY_MARKER')
      expect(readFileSync(sourceSkillPath, 'utf8')).toBe(sourceContent)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('calls official install on every prepare and trusts selected hooks idempotently', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-plugin-install-'))
    const libraryRoot = join(root, 'library')
    const projectRoot = join(root, 'project')
    createPlugin(libraryRoot, 'alpha', {})
    const prepared = prepareAgentPlugins({
      projectRoot,
      agentPlugins: agentPluginCatalog(libraryRoot, ['alpha']),
      libraryRoot,
      initializeProject: true,
      agentsContent: 'job guidance'
    })
    const calls: Array<{ method: string; params: unknown }> = []
    let trusted = false
    const client = {
      request: async (method: string, params: unknown) => {
        calls.push({ method, params })
        if (method === 'plugin/installed') {
          return { marketplaces: [{ plugins: [{ name: 'alpha', installed: true, enabled: true }] }] }
        }
        if (method === 'hooks/list') {
          return {
            data: [
              {
                cwd: '/workspace',
                hooks: [
                  {
                    key: 'alpha-hook',
                    pluginId: 'alpha@ankole-background-agent-job',
                    currentHash: 'hook-hash',
                    trustStatus: trusted ? 'trusted' : 'untrusted'
                  }
                ]
              }
            ]
          }
        }
        if (method === 'config/batchWrite') trusted = true
        return {}
      }
    }

    try {
      await installAndTrustAgentPlugins(client as any, '/workspace', prepared)
      await installAndTrustAgentPlugins(client as any, '/workspace', prepared)
      expect(calls.filter(call => call.method === 'plugin/install')).toHaveLength(2)
      expect(calls.filter(call => call.method === 'config/batchWrite')).toHaveLength(2)
      expect(calls.filter(call => call.method === 'plugin/install')[0]?.params).toEqual({
        marketplacePath: prepared.marketplacePath,
        pluginName: 'alpha'
      })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function createPlugin(
  libraryRoot: string,
  id: string,
  options: { config?: string; files?: Record<string, string>; skillsPath?: string }
): void {
  const root = join(libraryRoot, id)
  const skillsPath = options.skillsPath ?? 'skills'
  mkdirSync(join(root, '.codex-plugin'), { recursive: true })
  mkdirSync(join(root, skillsPath, `${id}-skill`), { recursive: true })
  writeFileSync(
    join(root, '.codex-plugin', 'plugin.json'),
    JSON.stringify({ name: id, version: '1.0.0', description: `${id} plugin`, skills: `./${skillsPath}/` })
  )
  writeFileSync(
    join(root, skillsPath, `${id}-skill`, 'SKILL.md'),
    `---\nname: ${id}-skill\ndescription: ${id} skill\n---\n`
  )
  if (options.config !== undefined) {
    mkdirSync(join(root, 'workspace-template', '.codex'), { recursive: true })
    writeFileSync(join(root, 'workspace-template', '.codex', 'config.toml'), options.config)
  }
  for (const [path, content] of Object.entries(options.files ?? {})) {
    const target = join(root, 'workspace-template', path)
    mkdirSync(join(target, '..'), { recursive: true })
    writeFileSync(target, content)
  }
}

function agentPluginCatalog(libraryRoot: string, ids: string[]): AgentPluginCatalogEntry[] {
  return ids.map(id =>
    create(AgentPluginCatalogEntrySchema, {
      id,
      description: `${id} plugin`,
      version: '1.0.0',
      contentHash: computeAgentPluginContentHash(join(libraryRoot, id)),
      skills: [{ catalogName: `${id}-skill`, codexName: `${id}:${id}-skill` }]
    })
  )
}

function turn(): ActorTurnRef {
  return {
    actor: { agent_uid: 'agent-1', session_id: 'job:job-1' },
    activation_uid: 'activation-1',
    actor_epoch: 1,
    actor_event_id: '00000000-0000-0000-0000-000000000001',
    revision: 0
  }
}
