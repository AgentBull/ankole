import { recordValue, stringArg, type JsonObject } from '@agentbull/active-support'
import { writeFileAtomic } from '../../../common/atomic-write'
import { chownAgentPathSync, mkdirAgent, mkdirAgentSync } from '../../../common/agent-user'
import { compareCodePointStrings } from '../../../common/ordering'
import { chmodSync, copyFileSync, existsSync, lstatSync, readFileSync, readdirSync, renameSync, rmSync } from 'node:fs'
import * as fsPromises from 'node:fs/promises'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { type AgentPluginCatalogEntry } from '../../../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { CodexAppServerClient } from './app-server-client'
import { sanitizePathSegment } from '../../agent-home-paths'
import { errorMessage } from '../../../common/errors'

/** Image-owned source for first-party Agent Plugin packages. */
export const BUILTIN_AGENT_PLUGINS_ROOT = '/repo/app/library/agent-plugins'
/** Stable local marketplace identity used by the Codex Plugin API. */
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

/**
 * Resolves the current catalog and initializes one selected workspace template.
 */
export function prepareAgentPlugins(input: {
  projectRoot: string
  agentPlugins: AgentPluginCatalogEntry[]
  codexHome: string
  libraryRoot?: string
  initializeProject: boolean
  workspaceTemplateId?: string
}): PreparedAgentPlugins {
  const libraryRoot = input.libraryRoot ?? BUILTIN_AGENT_PLUGINS_ROOT
  const materializedRoot = join(input.codexHome, 'runtime-materials', 'agent-plugins')
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
    initializeJobProjectAtomically(input.projectRoot, agentPlugins, input.workspaceTemplateId)
  }

  return {
    agentPlugins,
    marketplaceName: AGENT_PLUGIN_MARKETPLACE_NAME,
    marketplacePath: join(input.codexHome, '.agents', 'plugins', 'marketplace.json'),
    marketplaceRoot: input.codexHome,
    materializedRoot
  }
}

/**
 * Builds packages in the Worker-local Codex Home. AgentCodexRuntime serializes
 * the setup in this Codex Home.
 */
export async function materializeAgentPluginPackages(
  prepared: PreparedAgentPlugins,
  input: { rebuild: boolean }
): Promise<void> {
  const pluginsRoot = join(prepared.materializedRoot, 'plugins')
  await fsPromises.mkdir(pluginsRoot, { recursive: true, mode: 0o755 })
  if (input.rebuild) await removeStaleMaterializedPlugins(pluginsRoot, prepared.agentPlugins)
  await runWithConcurrency(prepared.agentPlugins, 4, async agentPlugin => {
    if (input.rebuild || !(await pathExists(agentPlugin.materializedRoot))) {
      await replaceMaterializedPlugin(agentPlugin)
    }
  })
  await writeMarketplace(prepared)
}

/**
 * Installs all same-release packages while no Job thread exists, trusts their
 * hooks, and leaves every global Plugin entry disabled. Job capabilities use
 * Ankole-owned tool and MCP projections instead of Codex Plugin Skill roots.
 */
export async function installTrustAndDisableAgentPlugins(
  client: Pick<CodexAppServerClient, 'request'>,
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

  await assertInstalledPluginState(client, prepared, true)
  const hooks = await selectedPluginHooks(client, prepared)
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
    const trustedHooks = await selectedPluginHooks(client, prepared)
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
  await assertInstalledPluginState(client, prepared, false)
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
  let manifest: JsonObject
  try {
    manifest = recordValue(JSON.parse(readFileSync(manifestPath, 'utf8'))) ?? {}
  } catch (error) {
    throw new Error(`invalid Agent Plugin manifest for ${agentPluginID}: ${errorMessage(error)}`)
  }

  const manifestName = requiredString(stringArg(manifest, 'name'), `Agent Plugin ${agentPluginID} manifest name`)
  const manifestVersion = requiredString(
    stringArg(manifest, 'version'),
    `Agent Plugin ${agentPluginID} manifest version`
  )
  const skillsRelativePath = manifestDirectoryPath(
    sourceRoot,
    stringArg(manifest, 'skills'),
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
  workspaceTemplateId: string | undefined
): void {
  const parent = dirname(projectRoot)
  mkdirAgentSync(parent)
  const stagedRoot = join(parent, `.project-init-${crypto.randomUUID()}`)
  try {
    mkdirAgentSync(stagedRoot, 0o700)
    mkdirAgentSync(join(stagedRoot, 'temp'))
    initializeWorkspaceTemplate(stagedRoot, agentPlugins, workspaceTemplateId)
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
      mkdirAgentSync(target)
      continue
    }
    if (existsSync(target)) {
      throw new Error(`Agent Plugin workspace template conflicts with existing Job project file: ${entry.relativePath}`)
    }
    mkdirAgentSync(dirname(target))
    copyFileSync(entry.absolutePath, target)
    chownAgentPathSync(target)
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

async function removeStaleMaterializedPlugins(pluginsRoot: string, agentPlugins: PreparedAgentPlugin[]): Promise<void> {
  const expected = new Set(agentPlugins.map(agentPlugin => agentPlugin.id))
  for (const entry of await fsPromises.readdir(pluginsRoot, { withFileTypes: true })) {
    if (expected.has(entry.name)) continue
    await fsPromises.rm(join(pluginsRoot, entry.name), { recursive: true, force: true })
  }
}

async function replaceMaterializedPlugin(agentPlugin: PreparedAgentPlugin): Promise<void> {
  const parent = dirname(agentPlugin.materializedRoot)
  await fsPromises.mkdir(parent, { recursive: true, mode: 0o755 })
  const stagedRoot = join(parent, `.plugin-${agentPlugin.id}-${crypto.randomUUID()}`)
  try {
    await copyDirectoryStrict(agentPlugin.sourceRoot, stagedRoot)
    await commitStagedDirectory(stagedRoot, agentPlugin.materializedRoot)
  } catch (error) {
    try {
      await fsPromises.rm(stagedRoot, { recursive: true, force: true })
    } catch {
      // The next rebuild removes leftovers. Keep the original setup failure.
    }
    throw error
  }
}

/**
 * Replaces the target with the staged directory. The current target survives
 * as a restored backup when the final rename fails.
 */
async function commitStagedDirectory(stagedRoot: string, targetRoot: string): Promise<void> {
  const backupRoot = `${stagedRoot}.backup`
  if (await pathExists(targetRoot)) await fsPromises.rename(targetRoot, backupRoot)
  try {
    await fsPromises.rename(stagedRoot, targetRoot)
  } catch (error) {
    if (await pathExists(backupRoot)) await fsPromises.rename(backupRoot, targetRoot)
    throw error
  }
  await fsPromises.rm(backupRoot, { recursive: true, force: true })
}

async function copyDirectoryStrict(sourceRoot: string, targetRoot: string): Promise<void> {
  if (await pathExists(targetRoot)) throw new Error(`Agent Plugin materialization target already exists: ${targetRoot}`)
  await fsPromises.mkdir(targetRoot, { recursive: true, mode: 0o755 })
  const entries = await listTemplateEntriesAsync(sourceRoot)
  for (const entry of entries) {
    if (entry.kind !== 'directory') continue
    await fsPromises.mkdir(join(targetRoot, ...entry.relativePath.split('/')), { recursive: true })
  }
  const files = entries.filter(entry => entry.kind === 'file')
  await runWithConcurrency(files, 16, async entry => {
    const target = join(targetRoot, ...entry.relativePath.split('/'))
    const sourceStat = await fsPromises.lstat(entry.absolutePath)
    await fsPromises.copyFile(entry.absolutePath, target)
    await fsPromises.chmod(target, (sourceStat.mode & 0o555) | 0o444)
  })
}

async function listTemplateEntriesAsync(
  root: string
): Promise<Array<{ kind: 'directory' | 'file'; relativePath: string; absolutePath: string }>> {
  const result: Array<{ kind: 'directory' | 'file'; relativePath: string; absolutePath: string }> = []
  const visit = async (directory: string): Promise<void> => {
    const entries = (await fsPromises.readdir(directory, { withFileTypes: true })).sort((left, right) =>
      Buffer.from(left.name).compare(Buffer.from(right.name))
    )
    for (const entry of entries) {
      const absolutePath = join(directory, entry.name)
      const relativePath = relative(root, absolutePath).split(sep).join('/')
      if (entry.isSymbolicLink()) throw new Error(`Agent Plugin packages cannot contain symlinks: ${relativePath}`)
      if (entry.isDirectory()) {
        result.push({ kind: 'directory', relativePath, absolutePath })
        await visit(absolutePath)
      } else if (entry.isFile()) {
        result.push({ kind: 'file', relativePath, absolutePath })
      } else {
        throw new Error(`Agent Plugin packages can contain only regular files and directories: ${relativePath}`)
      }
    }
  }
  await visit(root)
  return result
}

async function writeMarketplace(prepared: PreparedAgentPlugins): Promise<void> {
  await atomicWriteJSON(prepared.marketplacePath, {
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
  prepared: PreparedAgentPlugins,
  enabled: boolean
): Promise<void> {
  const response = recordValue(await client.request('plugin/installed', { cwds: [prepared.marketplaceRoot] })) ?? {}
  const sameName = arrayOfObjects(response.marketplaces).filter(
    candidate => candidate.name === prepared.marketplaceName
  )
  // Codex also discovers `$HOME/.agents/plugins`. A marketplace with the same
  // name there takes over the Plugin IDs, so Codex would read shared files.
  const shadowing = sameName.map(candidate => candidate.path).filter(path => path !== prepared.marketplacePath)
  if (shadowing.length > 0) {
    throw new Error(
      `Codex also discovers the ${prepared.marketplaceName} Plugin marketplace at ${shadowing.join(', ')}. Workers before 1.6.8-rc.1 left it in the Agent Home; an operator must remove it and the runtime-materials/agent-plugins directory of that Agent Home.`
    )
  }
  const marketplace = sameName.find(candidate => candidate.path === prepared.marketplacePath)
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
  prepared: PreparedAgentPlugins
): Promise<Array<{ key: string; currentHash: string; trustStatus?: string }>> {
  // Codex discovers a local marketplace from HOME or an explicit cwd, not CODEX_HOME.
  const cwd = prepared.marketplaceRoot
  const response = recordValue(await client.request('hooks/list', { cwds: [cwd] })) ?? {}
  const expectedPluginIDs = new Set(prepared.agentPlugins.map(agentPlugin => pluginKey(agentPlugin, prepared)))
  const entry =
    arrayOfObjects(response.data).find(candidate => candidate.cwd === cwd) ?? arrayOfObjects(response.data)[0]
  return arrayOfObjects(entry?.hooks)
    .filter(hook => {
      const pluginId = stringArg(hook, 'pluginId')
      return pluginId !== undefined && expectedPluginIDs.has(pluginId)
    })
    .map(hook => {
      const trustStatus = stringArg(hook, 'trustStatus')
      return {
        key: requiredString(stringArg(hook, 'key'), 'Agent Plugin hook key'),
        currentHash: requiredString(stringArg(hook, 'currentHash'), 'Agent Plugin hook currentHash'),
        ...(trustStatus !== undefined ? { trustStatus } : {})
      }
    })
}

function pluginKey(agentPlugin: PreparedAgentPlugin, prepared: PreparedAgentPlugins): string {
  return `${agentPlugin.manifestName}@${prepared.marketplaceName}`
}

async function atomicWriteJSON(path: string, value: unknown): Promise<void> {
  await mkdirAgent(dirname(path), 0o700)
  const content = `${JSON.stringify(value, null, 2)}\n`
  if ((await pathExists(path)) && (await fsPromises.readFile(path, 'utf8')) === content) return
  await writeFileAtomic(path, content, 0o600)
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await fsPromises.lstat(path)
    return true
  } catch (error) {
    if ((error as NodeJS.ErrnoException)?.code === 'ENOENT') return false
    throw error
  }
}

async function runWithConcurrency<T>(
  items: readonly T[],
  limit: number,
  worker: (item: T) => Promise<void>
): Promise<void> {
  if (items.length === 0) return
  let nextIndex = 0
  let firstError: unknown
  let hasError = false
  const runnerCount = Math.min(Math.max(limit, 1), items.length)
  const runners = Array.from({ length: runnerCount }, async () => {
    while (!hasError) {
      const index = nextIndex++
      if (index >= items.length) return
      try {
        await worker(items[index]!)
      } catch (error) {
        if (!hasError) {
          hasError = true
          firstError = error
        }
        return
      }
    }
  })
  await Promise.allSettled(runners)
  if (hasError) throw firstError
}

function arrayOfObjects(value: unknown): JsonObject[] {
  return Array.isArray(value) ? value.map(entry => recordValue(entry) ?? {}) : []
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
