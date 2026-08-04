import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { TOML } from 'bun'
import { AgentPluginCatalogEntrySchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  materializeAgentPluginPackages,
  materializeSelectedAgentPlugins,
  prepareAgentPlugins,
  selectAgentPluginCapabilities
} from '../src/core/codex-runner/agent-plugin-materializer'
import { assertCodexJobProjectResumeState } from '../src/core/codex-runner/job-project'
import type { AgentPluginCatalogEntry } from '../src/lanes/rpc_lane'

describe('@ankole/agent-computer Agent Plugin materializer', () => {
  it('selects Plugin Skills, copies one workspace template, and never recopies it on resume', () => {
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
        agentHome: join(root, 'agent-home'),
        libraryRoot,
        initializeProject: true,
        workspaceTemplateId: 'alpha',
        agentsContent: '# Job guidance'
      })
      expect(first.agentPlugins.map(plugin => plugin.id)).toEqual(['alpha', 'beta'])
      expect(existsSync(join(projectRoot, 'plugins'))).toBe(false)
      expect(existsSync(join(projectRoot, '.agents', 'plugins', 'marketplace.json'))).toBe(false)
      expect(TOML.parse(readFileSync(join(projectRoot, '.codex', 'config.toml'), 'utf8'))).toEqual({
        features: { plugins: true }
      })
      expect(existsSync(join(projectRoot, 'temp'))).toBeTrue()
      expect(existsSync(join(projectRoot, 'research', '.keep'))).toBe(false)
      expect(readFileSync(join(projectRoot, 'AGENTS.md'), 'utf8')).toBe('alpha instructions\n\n# Job guidance\n')

      writeFileSync(join(projectRoot, 'AGENTS.md'), 'job-local edit\n')
      const second = prepareAgentPlugins({
        projectRoot,
        agentPlugins: catalog,
        agentHome: join(root, 'agent-home'),
        libraryRoot,
        initializeProject: false
      })
      expect(second.agentPlugins.map(plugin => plugin.id)).toEqual(['alpha', 'beta'])
      expect(readFileSync(join(projectRoot, 'AGENTS.md'), 'utf8')).toBe('job-local edit\n')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('uses only the singular selected workspace template and rejects package symlinks', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-plugin-conflicts-'))
    const libraryRoot = join(root, 'library')
    createPlugin(libraryRoot, 'alpha', {
      config: '[features]\nplugins = true\n',
      files: { 'AGENTS.md': 'alpha\n' }
    })
    createPlugin(libraryRoot, 'file-conflict', { files: { 'AGENTS.md': 'other\n' } })
    createPlugin(libraryRoot, 'config-conflict', { config: '[features]\nplugins = false\n' })

    try {
      const prepared = prepareAgentPlugins({
        projectRoot: join(root, 'project'),
        agentPlugins: agentPluginCatalog(libraryRoot, ['alpha', 'file-conflict', 'config-conflict']),
        agentHome: join(root, 'agent-home'),
        libraryRoot,
        initializeProject: true,
        workspaceTemplateId: 'alpha',
        agentsContent: 'job guidance'
      })
      expect(prepared.agentPlugins.map(plugin => plugin.id)).toEqual(['alpha', 'config-conflict', 'file-conflict'])
      expect(readFileSync(join(root, 'project', 'AGENTS.md'), 'utf8')).toBe('alpha\n\njob guidance\n')
      expect(TOML.parse(readFileSync(join(root, 'project', '.codex', 'config.toml'), 'utf8'))).toEqual({
        features: { plugins: true }
      })

      const symlinkPlugin = join(libraryRoot, 'symlinked')
      createPlugin(libraryRoot, 'symlinked', {})
      symlinkSync(join(symlinkPlugin, '.codex-plugin', 'plugin.json'), join(symlinkPlugin, 'manifest-link'))
      expect(() =>
        prepareAgentPlugins({
          projectRoot: join(root, 'symlink-project'),
          agentPlugins: agentPluginCatalog(libraryRoot, ['symlinked']),
          agentHome: join(root, 'agent-home'),
          libraryRoot,
          initializeProject: true,
          agentsContent: 'job guidance'
        })
      ).toThrow('cannot contain symlinks')
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
        agentHome: join(root, 'agent-home'),
        libraryRoot,
        initializeProject: true,
        workspaceTemplateId: 'alpha',
        agentsContent: 'job guidance'
      })
      expect(readFileSync(join(projectRoot, 'AGENTS.md'), 'utf8')).toBe('complete\n\njob guidance\n')
      expect(
        readFileSync(join(prepared.agentPlugins[0]!.sourceRoot, '.codex-plugin', 'plugin.json'), 'utf8')
      ).toContain('"version":"1.0.0"')
      expect(readFileSync(external, 'utf8')).toBe('caller-owned\n')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('resolves the current package on resume without reapplying its workspace template', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-plugin-current-resume-'))
    const libraryRoot = join(root, 'library')
    const projectRoot = join(root, 'project')
    createPlugin(libraryRoot, 'alpha', { files: { 'v1.txt': 'initial template bytes\n' } })
    const initialCatalog = agentPluginCatalog(libraryRoot, ['alpha'])

    try {
      prepareAgentPlugins({
        projectRoot,
        agentPlugins: initialCatalog,
        agentHome: join(root, 'agent-home'),
        libraryRoot,
        initializeProject: true,
        workspaceTemplateId: 'alpha',
        agentsContent: 'job guidance'
      })
      writeFileSync(join(projectRoot, 'AGENTS.md'), 'preserved project guidance\n')
      rmSync(join(libraryRoot, 'alpha'), { recursive: true, force: true })
      createPlugin(libraryRoot, 'alpha', { files: { 'v2.txt': 'new image bytes\n' } })
      const currentCatalog = agentPluginCatalog(libraryRoot, ['alpha'])

      const resumed = prepareAgentPlugins({
        projectRoot,
        agentPlugins: currentCatalog,
        agentHome: join(root, 'agent-home'),
        libraryRoot,
        initializeProject: false
      })
      expect(resumed.agentPlugins[0]).toMatchObject({
        id: 'alpha'
      })
      expect(readFileSync(join(resumed.agentPlugins[0]!.sourceRoot, 'workspace-template', 'v2.txt'), 'utf8')).toBe(
        'new image bytes\n'
      )
      expect(readFileSync(join(projectRoot, 'AGENTS.md'), 'utf8')).toBe('preserved project guidance\n')
      expect(existsSync(join(projectRoot, 'v2.txt'))).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('fails closed when the job workspace is missing for a persisted thread', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-plugin-retained-project-'))
    const libraryRoot = join(root, 'library')
    const projectRoot = join(root, 'project')
    createPlugin(libraryRoot, 'alpha', {})
    try {
      prepareAgentPlugins({
        projectRoot,
        agentPlugins: agentPluginCatalog(libraryRoot, ['alpha']),
        agentHome: join(root, 'agent-home'),
        libraryRoot,
        initializeProject: true,
        agentsContent: 'job guidance'
      })
      rmSync(projectRoot, { recursive: true, force: true })
      expect(() => assertCodexJobProjectResumeState(projectRoot)).toThrow(
        'workspace is missing for a persisted runtime thread'
      )
      expect(existsSync(projectRoot)).toBe(false)
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
        agentHome: join(root, 'agent-home'),
        libraryRoot,
        initializeProject: true,
        agentsContent: 'job guidance'
      })

      expect(prepared.agentPlugins[0]).toMatchObject({
        skillsRelativePath: 'capabilities/skills',
        memberSkillNames: ['alpha-skill']
      })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('keeps the installed package stable and rebuilds a filtered Job Plugin view from current Skill material', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-plugin-live-skill-'))
    const libraryRoot = join(root, 'library')
    const agentHome = join(root, 'agent-home')
    const skillMaterialsRoot = join(agentHome, 'runtime-materials', 'skills')
    createPlugin(libraryRoot, 'alpha', {})
    mkdirSync(join(skillMaterialsRoot, 'alpha-skill'), { recursive: true })
    writeFileSync(join(skillMaterialsRoot, 'alpha-skill', 'SKILL.md'), 'overlay-v1\n')

    try {
      const prepared = prepareAgentPlugins({
        projectRoot: join(agentHome, 'jobs', '1000'),
        agentPlugins: agentPluginCatalog(libraryRoot, ['alpha']),
        agentHome,
        libraryRoot,
        initializeProject: false
      })
      const installedSkill = join(prepared.agentPlugins[0]!.materializedRoot, 'skills', 'alpha-skill', 'SKILL.md')
      const selectionRoot = join(agentHome, 'jobs', '1000', '.ankole', 'agent-plugins')

      materializeAgentPluginPackages(prepared, { rebuild: true })
      expect(readFileSync(installedSkill, 'utf8')).toContain('alpha skill')
      const selected = materializeSelectedAgentPlugins(prepared, agentPluginCatalog(libraryRoot, ['alpha']), {
        materializedRoot: selectionRoot,
        skillMaterialsRoot
      })
      const selectedSkill = join(selected.agentPlugins[0]!.materializedRoot, 'skills', 'alpha-skill', 'SKILL.md')
      expect(readFileSync(selectedSkill, 'utf8')).toBe('overlay-v1\n')

      const stalePlugin = join(prepared.materializedRoot, 'plugins', 'removed-plugin')
      mkdirSync(stalePlugin)
      writeFileSync(join(stalePlugin, 'stale'), 'old release\n')
      materializeAgentPluginPackages(prepared, { rebuild: true })
      expect(existsSync(stalePlugin)).toBe(false)

      writeFileSync(join(skillMaterialsRoot, 'alpha-skill', 'SKILL.md'), 'overlay-v2\n')
      materializeSelectedAgentPlugins(prepared, agentPluginCatalog(libraryRoot, ['alpha']), {
        materializedRoot: selectionRoot,
        skillMaterialsRoot
      })
      expect(readFileSync(selectedSkill, 'utf8')).toBe('overlay-v2\n')

      materializeSelectedAgentPlugins(prepared, [], { materializedRoot: selectionRoot, skillMaterialsRoot })
      expect(existsSync(selectedSkill)).toBe(false)
      expect(readFileSync(installedSkill, 'utf8')).toContain('alpha skill')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('keeps projected Plugin members disabled when current Agent settings remove them', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-agent-plugin-current-disable-'))
    const libraryRoot = join(root, 'library')
    const agentHome = join(root, 'agent-home')
    createPlugin(libraryRoot, 'alpha', {})

    try {
      const prepared = prepareAgentPlugins({
        projectRoot: join(agentHome, 'jobs', '1000'),
        agentPlugins: [],
        agentHome,
        libraryRoot,
        initializeProject: false
      })
      const selected = materializeSelectedAgentPlugins(prepared, [], {
        materializedRoot: join(agentHome, 'jobs', '1000', '.ankole', 'agent-plugins'),
        skillMaterialsRoot: join(agentHome, 'runtime-materials', 'skills')
      })
      const capabilities = selectAgentPluginCapabilities(selected, [], [{ id: 'alpha', skills: ['alpha-skill'] }])

      expect(selected.agentPlugins).toEqual([])
      expect(capabilities.selectedCapabilityRoots).toEqual([])
      expect(capabilities.availableSkillNames).toEqual([])
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
      hasWorkspaceTemplate: existsSync(join(libraryRoot, id, 'workspace-template')),
      skills: [{ catalogName: `${id}-skill` }]
    })
  )
}
