import { compareCodePointStrings } from '../../common/ordering'
import {
  chmodSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync
} from 'node:fs'
import { dirname, join, relative, resolve, sep } from 'node:path'
import type { AgentPluginCatalogEntry } from '../../lanes/rpc_lane'
import type { CodexAppServerClient } from './app-server-client'
import { sanitizePathSegment } from '../agent-home-paths'
import { errorMessage } from '../../common/errors'

export const BUILTIN_AGENT_PLUGINS_ROOT = '/repo/app/library/agent-plugins'
export const AGENT_PLUGIN_MARKETPLACE_NAME = 'ankole-agent-runtime'

export type PreparedAgentPlugin = {
  id: string
  hasWorkspaceTemplate: boolean
  manifestName: string
  manifestVersion: string
  skillsRelativePath: string
  sourceRoot: string
  materializedRoot: string
  memberSkillNames: string[]
}

export type PreparedAgentPlugins = {
  agentPlugins: PreparedAgentPlugin[]
  marketplaceName: string
  marketplacePath: string
  marketplaceRoot: string
  materializedRoot: string
}

export type SelectedAgentPluginCapabilities = {
  availableSkillNames: string[]
  discoveredSkills: Array<{ name: string; invocationNames: string[]; path: string; enabled: boolean }>
  selectedCapabilityRoots: Array<{
    id: string
    location: { type: 'environment'; environmentId: string; path: string }
  }>
}

/**
 * Resolves the current catalog and initializes one selected workspace template.
 */
export function prepareAgentPlugins(input: {
  projectRoot: string
  agentPlugins: AgentPluginCatalogEntry[]
  agentHome: string
  libraryRoot?: string
  initializeProject: boolean
  workspaceTemplateId?: string
  agentsContent?: string
}): PreparedAgentPlugins {
  const libraryRoot = input.libraryRoot ?? BUILTIN_AGENT_PLUGINS_ROOT
  const materializedRoot = join(input.agentHome, 'runtime-materials', 'agent-plugins')
  const catalog = [...input.agentPlugins].sort((left, right) => compareCodePointStrings(left.id, right.id))
  assertUniqueAgentPluginIDs(catalog)
  const catalogByID = new Map(catalog.map(agentPlugin => [agentPlugin.id, agentPlugin]))
  const packageIDs = agentPluginPackageIDs(libraryRoot)
  for (const agentPlugin of catalog) {
    if (!packageIDs.includes(agentPlugin.id)) {
      throw new Error(`Enabled Agent Plugin package is unavailable in this Worker image: ${agentPlugin.id}`)
    }
  }

  const agentPlugins = packageIDs.map(agentPluginID =>
    validateAgentPluginRef(libraryRoot, materializedRoot, agentPluginID, catalogByID.get(agentPluginID))
  )

  if (input.initializeProject) {
    initializeJobProjectAtomically(
      input.projectRoot,
      agentPlugins,
      input.workspaceTemplateId,
      input.agentsContent ?? ''
    )
  }

  return {
    agentPlugins,
    marketplaceName: AGENT_PLUGIN_MARKETPLACE_NAME,
    marketplacePath: join(input.agentHome, '.agents', 'plugins', 'marketplace.json'),
    marketplaceRoot: input.agentHome,
    materializedRoot
  }
}

/**
 * Builds the stable Agent-owned packages used by official Codex Plugin APIs.
 * AgentCodexRuntime serializes all calls to this function.
 */
export function materializeAgentPluginPackages(prepared: PreparedAgentPlugins, input: { rebuild: boolean }): void {
  const pluginsRoot = join(prepared.materializedRoot, 'plugins')
  mkdirSync(pluginsRoot, { recursive: true, mode: 0o700 })
  if (input.rebuild) removeStaleMaterializedPlugins(pluginsRoot, prepared.agentPlugins)
  for (const agentPlugin of prepared.agentPlugins) {
    if (input.rebuild || !existsSync(agentPlugin.materializedRoot)) {
      replaceMaterializedPlugin(agentPlugin)
    }
  }
  writeMarketplace(prepared)
}

/**
 * Builds one Job-owned Plugin view that contains only its currently allowed
 * projected members. Official installation still uses the Agent-owned package.
 */
export function materializeSelectedAgentPlugins(
  prepared: PreparedAgentPlugins,
  selected: AgentPluginCatalogEntry[],
  input: { materializedRoot: string; skillMaterialsRoot: string }
): PreparedAgentPlugins {
  const selections = [...selected].sort((left, right) => compareCodePointStrings(left.id, right.id))
  assertUniqueAgentPluginIDs(selections)
  const preparedByID = new Map(prepared.agentPlugins.map(agentPlugin => [agentPlugin.id, agentPlugin]))
  const parent = dirname(input.materializedRoot)
  mkdirSync(parent, { recursive: true, mode: 0o700 })
  const stagedRoot = join(parent, `.agent-plugins-${crypto.randomUUID()}`)
  const materializedPlugins: PreparedAgentPlugin[] = []

  try {
    const stagedPluginsRoot = join(stagedRoot, 'plugins')
    mkdirSync(stagedPluginsRoot, { recursive: true, mode: 0o700 })
    for (const selection of selections) {
      const source = preparedByID.get(selection.id)
      if (!source) throw new Error(`Selected Agent Plugin package is unavailable: ${selection.id}`)
      const selectedSkillNames = [...new Set(selection.skills.map(skill => skill.catalogName))].sort(
        compareCodePointStrings
      )
      if (selectedSkillNames.length === 0) continue
      for (const name of selectedSkillNames) {
        if (!source.memberSkillNames.includes(name)) {
          throw new Error(`Selected Agent Plugin Skill is unavailable: ${selection.id}/${name}`)
        }
      }

      const target = join(stagedPluginsRoot, source.id)
      copyDirectoryStrict(source.sourceRoot, target)
      filterMaterializedPluginSkills(source, target, selectedSkillNames, input.skillMaterialsRoot)
      materializedPlugins.push({
        ...source,
        materializedRoot: join(input.materializedRoot, 'plugins', source.id),
        memberSkillNames: selectedSkillNames
      })
    }

    commitStagedDirectory(stagedRoot, input.materializedRoot)
  } catch (error) {
    rmSync(stagedRoot, { recursive: true, force: true })
    throw error
  }

  return {
    ...prepared,
    agentPlugins: materializedPlugins,
    materializedRoot: input.materializedRoot
  }
}

export type JobAgentPluginMaterials = {
  materialize(): PreparedAgentPlugins
  disableSkills(skillNames: string[]): boolean
}

/**
 * Owns the mutable Skill selection of one running Job. `disableSkills` narrows
 * the selection and rebuilds the Job-owned Plugin view when it changes.
 */
export function createJobAgentPluginMaterials(input: {
  prepared: PreparedAgentPlugins
  selected: AgentPluginCatalogEntry[]
  materializedRoot: string
  skillMaterialsRoot: string
}): JobAgentPluginMaterials {
  const selectableSkillNames = new Set(
    input.selected.flatMap(agentPlugin => agentPlugin.skills.map(skill => skill.catalogName))
  )
  const disabledSkills = new Set<string>()
  const materialize = (): PreparedAgentPlugins =>
    materializeSelectedAgentPlugins(
      input.prepared,
      input.selected.map(agentPlugin => ({
        ...agentPlugin,
        skills: agentPlugin.skills.filter(skill => !disabledSkills.has(skill.catalogName))
      })),
      { materializedRoot: input.materializedRoot, skillMaterialsRoot: input.skillMaterialsRoot }
    )

  return {
    materialize,
    disableSkills: skillNames => {
      let changed = false
      for (const name of skillNames) {
        if (!selectableSkillNames.has(name) || disabledSkills.has(name)) continue
        disabledSkills.add(name)
        changed = true
      }
      if (changed) materialize()
      return changed
    }
  }
}

/**
 * Installs all same-release packages while no Job thread exists, trusts their
 * hooks, and leaves every global Plugin entry disabled. Jobs select roots on
 * thread/start instead of inheriting the Agent-wide installed set.
 */
export async function installTrustAndDisableAgentPlugins(
  client: Pick<CodexAppServerClient, 'request'>,
  cwd: string,
  prepared: PreparedAgentPlugins
): Promise<void> {
  await client.request('config/batchWrite', {
    edits: [{ keyPath: 'features.plugins', value: true, mergeStrategy: 'upsert' }],
    reloadUserConfig: true
  })
  for (const agentPlugin of prepared.agentPlugins) {
    await client.request('plugin/install', {
      marketplacePath: prepared.marketplacePath,
      pluginName: agentPlugin.manifestName
    })
  }
  if (prepared.agentPlugins.length === 0) return

  await assertInstalledPluginState(client, cwd, prepared, true)
  const hooks = await selectedPluginHooks(client, cwd, prepared)
  if (hooks.length > 0) {
    await client.request('config/batchWrite', {
      edits: [
        {
          keyPath: 'hooks.state',
          value: Object.fromEntries(hooks.map(hook => [hook.key, { trusted_hash: hook.currentHash }])),
          mergeStrategy: 'upsert'
        }
      ],
      reloadUserConfig: true
    })
    const trustedHooks = await selectedPluginHooks(client, cwd, prepared)
    const untrusted = trustedHooks.filter(hook => hook.trustStatus !== 'trusted')
    if (untrusted.length > 0) {
      throw new Error(`Agent Plugin hooks remain untrusted: ${untrusted.map(hook => hook.key).join(', ')}`)
    }
  }

  await client.request('config/batchWrite', {
    edits: [
      {
        keyPath: 'plugins',
        value: Object.fromEntries(
          prepared.agentPlugins.map(agentPlugin => [pluginKey(agentPlugin, prepared), { enabled: false }])
        ),
        mergeStrategy: 'upsert'
      }
    ],
    reloadUserConfig: true
  })
  await assertInstalledPluginState(client, cwd, prepared, false)
}

export function selectAgentPluginCapabilities(
  prepared: PreparedAgentPlugins,
  selected: AgentPluginCatalogEntry[],
  projected: Array<{ id: string; skills: string[] }> = selected.map(agentPlugin => ({
    id: agentPlugin.id,
    skills: agentPlugin.skills.map(skill => skill.catalogName)
  }))
): SelectedAgentPluginCapabilities {
  const preparedByID = new Map(prepared.agentPlugins.map(agentPlugin => [agentPlugin.id, agentPlugin]))
  const selectedByID = new Map(selected.map(agentPlugin => [agentPlugin.id, agentPlugin]))
  const availableSkillNames: string[] = []
  const discoveredSkills: SelectedAgentPluginCapabilities['discoveredSkills'] = []
  const selectedCapabilityRoots: SelectedAgentPluginCapabilities['selectedCapabilityRoots'] = []

  const projectedIDs = new Set<string>()
  for (const projection of [...projected].sort((left, right) => compareCodePointStrings(left.id, right.id))) {
    if (projectedIDs.has(projection.id)) throw new Error(`Projected Agent Plugin is duplicated: ${projection.id}`)
    projectedIDs.add(projection.id)
    const agentPlugin = preparedByID.get(projection.id)
    if (!agentPlugin) continue
    const selection = selectedByID.get(projection.id)
    const projectedSkillNames = new Set(projection.skills)
    const selectedSkillNames = new Set((selection?.skills ?? []).map(skill => skill.catalogName))
    for (const name of selectedSkillNames) {
      if (!agentPlugin.memberSkillNames.includes(name)) {
        throw new Error(`Selected Agent Plugin Skill is unavailable: ${projection.id}/${name}`)
      }
      if (!projectedSkillNames.has(name)) {
        throw new Error(`Selected Agent Plugin Skill was not projected for this Job: ${projection.id}/${name}`)
      }
    }

    if (selectedSkillNames.size > 0) {
      selectedCapabilityRoots.push({
        id: pluginKey(agentPlugin, prepared),
        location: { type: 'environment', environmentId: 'local', path: agentPlugin.materializedRoot }
      })
    }
    for (const name of agentPlugin.memberSkillNames) {
      const path = join(agentPlugin.materializedRoot, ...agentPlugin.skillsRelativePath.split('/'), name, 'SKILL.md')
      const enabled = selectedSkillNames.has(name)
      if (!enabled) continue
      availableSkillNames.push(name)
      discoveredSkills.push({
        name,
        invocationNames: [`${agentPlugin.manifestName}:${name}`],
        path,
        enabled: true
      })
    }
  }

  return {
    availableSkillNames: availableSkillNames.sort(compareCodePointStrings),
    discoveredSkills: discoveredSkills.sort((left, right) => compareCodePointStrings(left.name, right.name)),
    selectedCapabilityRoots
  }
}

function validateAgentPluginRef(
  sourcePackagesRoot: string,
  materializedPackagesRoot: string,
  agentPluginID: string,
  ref: AgentPluginCatalogEntry | undefined
): PreparedAgentPlugin {
  assertAgentPluginID(agentPluginID)
  const sourceRoot = join(sourcePackagesRoot, agentPluginID)
  const manifestPath = join(sourceRoot, '.codex-plugin', 'plugin.json')
  let manifest: Record<string, unknown>
  try {
    manifest = asObject(JSON.parse(readFileSync(manifestPath, 'utf8')))
  } catch (error) {
    throw new Error(`invalid Agent Plugin manifest for ${agentPluginID}: ${errorMessage(error)}`)
  }

  const manifestName = requiredString(manifest.name, `Agent Plugin ${agentPluginID} manifest name`)
  const manifestVersion = requiredString(manifest.version, `Agent Plugin ${agentPluginID} manifest version`)
  const skillsRelativePath = manifestDirectoryPath(
    sourceRoot,
    manifest.skills,
    `Agent Plugin ${agentPluginID} manifest skills`
  )
  if (manifestName !== agentPluginID) {
    throw new Error(`Agent Plugin id/manifest name mismatch: ${agentPluginID}/${manifestName}`)
  }

  const packageEntries = listTemplateEntries(sourceRoot)
  const memberSkillNames = memberSkillNamesFromEntries(packageEntries, skillsRelativePath)
  const enabledSkillNames = (ref?.skills ?? []).map(skill => skill.catalogName).sort(compareCodePointStrings)
  for (const name of enabledSkillNames) {
    if (!memberSkillNames.includes(name)) {
      throw new Error(`Enabled Agent Plugin Skill is unavailable in this Worker image: ${agentPluginID}/${name}`)
    }
  }
  return {
    id: agentPluginID,
    hasWorkspaceTemplate: existsSync(join(sourceRoot, 'workspace-template')),
    manifestName,
    manifestVersion,
    skillsRelativePath,
    sourceRoot,
    materializedRoot: join(materializedPackagesRoot, 'plugins', agentPluginID),
    memberSkillNames
  }
}

function initializeJobProjectAtomically(
  projectRoot: string,
  agentPlugins: PreparedAgentPlugin[],
  workspaceTemplateId: string | undefined,
  agentsContent: string
): void {
  const parent = dirname(projectRoot)
  mkdirSync(parent, { recursive: true })
  const stagedRoot = join(parent, `.project-init-${crypto.randomUUID()}`)
  try {
    mkdirSync(stagedRoot, { mode: 0o700 })
    mkdirSync(join(stagedRoot, 'temp'))
    initializeWorkspaceTemplate(stagedRoot, agentPlugins, workspaceTemplateId)
    appendProjectAgents(stagedRoot, agentsContent)
    if (existsSync(projectRoot)) {
      const current = lstatSync(projectRoot)
      if (current.isSymbolicLink() || !current.isDirectory()) {
        throw new Error('Background agent Job project must be a real directory before Agent Plugin recovery')
      }
      // No runtime thread exists yet, so a partial private project is safe to rebuild.
      rmSync(projectRoot, { recursive: true, force: true })
    }
    renameSync(stagedRoot, projectRoot)
  } catch (error) {
    rmSync(stagedRoot, { recursive: true, force: true })
    throw error
  }
}

function appendProjectAgents(projectRoot: string, content: string): void {
  const guidance = content.trim()
  if (!guidance) throw new Error('Background agent Job guidance is required during project initialization')

  const path = join(projectRoot, 'AGENTS.md')
  const existing = existsSync(path) ? readFileSync(path, 'utf8').trimEnd() : ''
  writeFileSync(path, `${existing ? `${existing}\n\n` : ''}${guidance}\n`, { mode: 0o600 })
}

function initializeWorkspaceTemplate(
  projectRoot: string,
  agentPlugins: PreparedAgentPlugin[],
  workspaceTemplateId: string | undefined
): void {
  if (!workspaceTemplateId) return
  const agentPlugin = agentPlugins.find(candidate => candidate.id === workspaceTemplateId)
  if (!agentPlugin) throw new Error(`Workspace template Agent Plugin is unavailable: ${workspaceTemplateId}`)
  if (!agentPlugin.hasWorkspaceTemplate) {
    throw new Error(`Agent Plugin has no workspace-template: ${workspaceTemplateId}`)
  }

  const templateRoot = join(agentPlugin.sourceRoot, 'workspace-template')
  if (!existsSync(templateRoot) || !lstatSync(templateRoot).isDirectory()) {
    throw new Error(`Agent Plugin workspace-template is not a directory: ${workspaceTemplateId}`)
  }

  for (const entry of listTemplateEntries(templateRoot)) {
    const target = join(projectRoot, ...entry.relativePath.split('/'))
    if (entry.kind === 'directory') {
      mkdirSync(target, { recursive: true })
      continue
    }
    if (existsSync(target)) {
      throw new Error(`Agent Plugin workspace template conflicts with existing Job project file: ${entry.relativePath}`)
    }
    mkdirSync(dirname(target), { recursive: true })
    copyFileSync(entry.absolutePath, target)
    chmodSync(target, lstatSync(entry.absolutePath).mode & 0o777)
  }
}

function listTemplateEntries(
  root: string
): Array<{ kind: 'directory' | 'file'; relativePath: string; absolutePath: string }> {
  const result: Array<{ kind: 'directory' | 'file'; relativePath: string; absolutePath: string }> = []
  const visit = (directory: string): void => {
    const entries = readdirSync(directory, { withFileTypes: true }).sort((left, right) =>
      Buffer.from(left.name).compare(Buffer.from(right.name))
    )
    for (const entry of entries) {
      const absolutePath = join(directory, entry.name)
      const relativePath = relative(root, absolutePath).split(sep).join('/')
      if (entry.isSymbolicLink()) throw new Error(`Agent Plugin packages cannot contain symlinks: ${relativePath}`)
      if (entry.isDirectory()) {
        result.push({ kind: 'directory', relativePath, absolutePath })
        visit(absolutePath)
      } else if (entry.isFile()) {
        result.push({ kind: 'file', relativePath, absolutePath })
      } else {
        throw new Error(`Agent Plugin packages can contain only regular files and directories: ${relativePath}`)
      }
    }
  }
  visit(root)
  return result
}

function memberSkillNamesFromEntries(
  entries: Array<{ kind: 'directory' | 'file'; relativePath: string }>,
  skillsRelativePath: string
): string[] {
  const prefix = `${skillsRelativePath}/`
  return entries
    .filter(entry => entry.kind === 'file' && entry.relativePath.startsWith(prefix))
    .map(entry => entry.relativePath.slice(prefix.length).split('/'))
    .filter(segments => segments.length === 2 && segments[1] === 'SKILL.md')
    .map(segments => segments[0]!)
    .sort(compareCodePointStrings)
}

function manifestDirectoryPath(packageRoot: string, value: unknown, label: string): string {
  const declaredPath = requiredString(value, label)
  if (!declaredPath.startsWith('./')) throw new Error(`${label} must be a package-relative directory`)

  const relativePath = declaredPath.slice(2).replace(/\/+$/, '')
  const absolutePath = resolve(packageRoot, relativePath)
  const root = resolve(packageRoot)
  if (!relativePath || absolutePath === root || !absolutePath.startsWith(`${root}${sep}`)) {
    throw new Error(`${label} must stay inside the Agent Plugin package`)
  }
  if (!existsSync(absolutePath) || !lstatSync(absolutePath).isDirectory()) {
    throw new Error(`${label} is not a directory`)
  }
  return relative(root, absolutePath).split(sep).join('/')
}

function agentPluginPackageIDs(libraryRoot: string): string[] {
  return readdirSync(libraryRoot, { withFileTypes: true })
    .filter(entry => entry.isDirectory() && existsSync(join(libraryRoot, entry.name, '.codex-plugin', 'plugin.json')))
    .map(entry => entry.name)
    .sort(compareCodePointStrings)
}

function removeStaleMaterializedPlugins(pluginsRoot: string, agentPlugins: PreparedAgentPlugin[]): void {
  const expected = new Set(agentPlugins.map(agentPlugin => agentPlugin.id))
  for (const entry of readdirSync(pluginsRoot, { withFileTypes: true })) {
    if (expected.has(entry.name)) continue
    rmSync(join(pluginsRoot, entry.name), { recursive: true, force: true })
  }
}

function replaceMaterializedPlugin(agentPlugin: PreparedAgentPlugin): void {
  const parent = dirname(agentPlugin.materializedRoot)
  mkdirSync(parent, { recursive: true, mode: 0o700 })
  const stagedRoot = join(parent, `.plugin-${agentPlugin.id}-${crypto.randomUUID()}`)
  try {
    copyDirectoryStrict(agentPlugin.sourceRoot, stagedRoot)
    commitStagedDirectory(stagedRoot, agentPlugin.materializedRoot)
  } catch (error) {
    rmSync(stagedRoot, { recursive: true, force: true })
    throw error
  }
}

/**
 * Replaces the target with the staged directory. The current target survives
 * as a restored backup when the final rename fails.
 */
function commitStagedDirectory(stagedRoot: string, targetRoot: string): void {
  const backupRoot = `${stagedRoot}.backup`
  if (existsSync(targetRoot)) renameSync(targetRoot, backupRoot)
  try {
    renameSync(stagedRoot, targetRoot)
  } catch (error) {
    if (existsSync(backupRoot)) renameSync(backupRoot, targetRoot)
    throw error
  }
  rmSync(backupRoot, { recursive: true, force: true })
}

function filterMaterializedPluginSkills(
  agentPlugin: PreparedAgentPlugin,
  packageRoot: string,
  selectedSkillNames: string[],
  skillMaterialsRoot: string
): void {
  const selected = new Set(selectedSkillNames)
  for (const name of agentPlugin.memberSkillNames) {
    const target = join(packageRoot, ...agentPlugin.skillsRelativePath.split('/'), name, 'SKILL.md')
    if (!selected.has(name)) {
      rmSync(target, { force: true })
      continue
    }
    const materialPath = join(skillMaterialsRoot, name, 'SKILL.md')
    if (!existsSync(materialPath)) continue
    const temporary = `${target}.tmp-${process.pid}-${crypto.randomUUID()}`
    copyFileSync(materialPath, temporary)
    chmodSync(temporary, 0o600)
    renameSync(temporary, target)
  }
}

function copyDirectoryStrict(sourceRoot: string, targetRoot: string): void {
  if (existsSync(targetRoot)) throw new Error(`Agent Plugin materialization target already exists: ${targetRoot}`)
  mkdirSync(targetRoot, { recursive: true, mode: 0o700 })
  for (const entry of listTemplateEntries(sourceRoot)) {
    const target = join(targetRoot, ...entry.relativePath.split('/'))
    if (entry.kind === 'directory') {
      mkdirSync(target, { recursive: true })
      continue
    }
    mkdirSync(dirname(target), { recursive: true })
    copyFileSync(entry.absolutePath, target)
    chmodSync(target, lstatSync(entry.absolutePath).mode & 0o777)
  }
}

function writeMarketplace(prepared: PreparedAgentPlugins): void {
  atomicWriteJSON(prepared.marketplacePath, {
    name: prepared.marketplaceName,
    plugins: prepared.agentPlugins.map(agentPlugin => ({
      name: agentPlugin.manifestName,
      source: {
        source: 'local',
        path: `./${relative(prepared.marketplaceRoot, agentPlugin.materializedRoot).split(sep).join('/')}`
      },
      policy: { installation: 'AVAILABLE', authentication: 'ON_INSTALL' },
      category: 'Developer Tools'
    }))
  })
}

async function assertInstalledPluginState(
  client: Pick<CodexAppServerClient, 'request'>,
  cwd: string,
  prepared: PreparedAgentPlugins,
  enabled: boolean
): Promise<void> {
  const response = asObject(await client.request('plugin/installed', { cwds: [cwd] }))
  const marketplace = arrayOfObjects(response.marketplaces).find(
    candidate => candidate.name === prepared.marketplaceName
  )
  const installedPlugins = arrayOfObjects(marketplace?.plugins)
  for (const agentPlugin of prepared.agentPlugins) {
    const observation = installedPlugins.find(candidate => candidate.name === agentPlugin.manifestName)
    if (!observation || observation.installed !== true || observation.enabled !== enabled) {
      throw new Error(
        `Codex Agent Plugin state mismatch for ${agentPlugin.id}: expected installed=true enabled=${enabled}, observed=${JSON.stringify(observation ?? null)}, installed=${JSON.stringify(response)}`
      )
    }
  }
}

async function selectedPluginHooks(
  client: Pick<CodexAppServerClient, 'request'>,
  cwd: string,
  prepared: PreparedAgentPlugins
): Promise<Array<{ key: string; currentHash: string; trustStatus?: string }>> {
  const response = asObject(await client.request('hooks/list', { cwds: [cwd] }))
  const expectedPluginIDs = new Set(prepared.agentPlugins.map(agentPlugin => pluginKey(agentPlugin, prepared)))
  const entry =
    arrayOfObjects(response.data).find(candidate => candidate.cwd === cwd) ?? arrayOfObjects(response.data)[0]
  return arrayOfObjects(entry?.hooks)
    .filter(hook => typeof hook.pluginId === 'string' && expectedPluginIDs.has(hook.pluginId))
    .map(hook => ({
      key: requiredString(hook.key, 'Agent Plugin hook key'),
      currentHash: requiredString(hook.currentHash, 'Agent Plugin hook currentHash'),
      ...(typeof hook.trustStatus === 'string' ? { trustStatus: hook.trustStatus } : {})
    }))
}

function pluginKey(agentPlugin: PreparedAgentPlugin, prepared: PreparedAgentPlugins): string {
  return `${agentPlugin.manifestName}@${prepared.marketplaceName}`
}

function atomicWriteJSON(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  const content = `${JSON.stringify(value, null, 2)}\n`
  if (existsSync(path) && readFileSync(path, 'utf8') === content) return
  const temporary = `${path}.tmp-${process.pid}-${crypto.randomUUID()}`
  writeFileSync(temporary, content, { mode: 0o600 })
  renameSync(temporary, path)
  chmodSync(path, 0o600)
}

function arrayOfObjects(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value) ? value.map(asObject) : []
}

function assertUniqueAgentPluginIDs(refs: AgentPluginCatalogEntry[]): void {
  const ids = new Set<string>()
  for (const ref of refs) {
    if (ids.has(ref.id)) throw new Error(`Agent Plugin id is duplicated: ${ref.id}`)
    ids.add(ref.id)
  }
}

function assertAgentPluginID(id: string): void {
  if (!id || id === '.' || id === '..' || sanitizePathSegment(id, { replacement: '_' }) !== id) {
    throw new Error(`Agent Plugin id is not a safe path segment: ${id || '<empty>'}`)
  }
}

function requiredString(value: unknown, label: string): string {
  if (typeof value !== 'string' || value.length === 0) throw new Error(`${label} is required`)
  return value
}

function asObject(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : {}
}
