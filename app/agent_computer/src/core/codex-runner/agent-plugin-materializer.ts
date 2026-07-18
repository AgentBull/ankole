import { genericHash } from '@ankole/kernel'
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
import type { ActorTurnRef } from '../../lanes/actor_lane'
import type { AgentPluginCatalogEntry, RPCRequester, RuntimeSkillSummary } from '../../lanes/rpc_lane'
import { composeNativeSkillFile, resolveSkillOverlayText } from '../../skills/effective-skill'
import type { CodexAppServerClient } from '../../tools/codex/app-server-client'
import { sanitizePathSegment } from '../workspace-paths'

export const BUILTIN_AGENT_PLUGINS_ROOT = '/repo/app/library/agent-plugins'
const CONTENT_HASH_PREFIX = Buffer.from('ankole-agent-plugin-v1\0')
const MARKETPLACE_NAME = 'ankole-background-agent-job'
const MAX_PACKAGE_FILES = 2_048
const MAX_PACKAGE_FILE_BYTES = 8 * 1024 * 1024
const MAX_PACKAGE_CONTENT_BYTES = 64 * 1024 * 1024
const MAX_PACKAGE_PATH_BYTES = 4_096

export type PreparedAgentPlugin = AgentPluginCatalogEntry & {
  manifestName: string
  skillsRelativePath: string
  sourceRoot: string
  materializedRoot: string
  memberSkillNames: string[]
  enabledSkillNames: string[]
  enabledCodexSkillNames: string[]
}

export type PreparedAgentPlugins = {
  marketplaceHostPath: string
  marketplacePath: string
  marketplaceName: typeof MARKETPLACE_NAME
  pluginsRoot: string
  agentPlugins: PreparedAgentPlugin[]
  expectedSkillNames: string[]
}

export function assertAgentPluginProjectResumeState(projectRoot: string): void {
  if (!existsSync(projectRoot)) {
    throw new Error('Background agent Job project is missing for a persisted runtime thread')
  }
  const stat = lstatSync(projectRoot)
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    throw new Error('Background agent Job project must be a real directory for a persisted runtime thread')
  }
}

/**
 * Resolves the current catalog packages into the Job-local marketplace. The
 * workspace template and Job guidance initialize only the pre-thread project;
 * later prepares refresh only the rebuildable Plugin packages.
 */
export function prepareAgentPlugins(input: {
  projectRoot: string
  agentPlugins: AgentPluginCatalogEntry[]
  libraryRoot?: string
  initializeProject: boolean
  agentsContent?: string
}): PreparedAgentPlugins {
  const libraryRoot = input.libraryRoot ?? BUILTIN_AGENT_PLUGINS_ROOT
  const catalog = [...input.agentPlugins].sort((left, right) => compareCodePoints(left.id, right.id))
  assertUniqueAgentPluginIDs(catalog)

  const pluginsRoot = join(input.projectRoot, 'plugins')
  const agentPlugins = catalog.map(agentPlugin => validateAgentPluginRef(libraryRoot, pluginsRoot, agentPlugin))

  if (input.initializeProject) {
    initializeJobProjectAtomically(input.projectRoot, agentPlugins, input.agentsContent ?? '')
  } else {
    refreshAgentPluginPackages(pluginsRoot, agentPlugins)
  }

  const marketplacePath = writeMarketplace(input.projectRoot, agentPlugins)

  return {
    marketplaceHostPath: resolve(marketplacePath),
    marketplacePath: '/workspace/.agents/plugins/marketplace.json',
    marketplaceName: MARKETPLACE_NAME,
    pluginsRoot,
    agentPlugins,
    expectedSkillNames: agentPlugins.flatMap(agentPlugin => agentPlugin.enabledCodexSkillNames).sort(compareCodePoints)
  }
}

/** Applies current DB-backed overlays to the Job-local copies of enabled Plugin Skills. */
export async function materializeAgentPluginSkillOverlays(input: {
  prepared: PreparedAgentPlugins
  enabledSkills: RuntimeSkillSummary[]
  turn: ActorTurnRef
  rpc: RPCRequester
}): Promise<void> {
  const pluginsByID = new Map(input.prepared.agentPlugins.map(agentPlugin => [agentPlugin.id, agentPlugin]))
  const seen = new Set<string>()

  for (const skill of [...input.enabledSkills].sort(compareAgentPluginSkills)) {
    const agentPluginID = skill.agentPluginId
    const key = `${agentPluginID}\0${skill.skillName}`
    if (!agentPluginID || !skill.skillName || seen.has(key)) {
      throw new Error(
        `Agent Plugin overlay input has duplicate or invalid member: ${agentPluginID || '<empty>'}/${skill.skillName || '<empty>'}`
      )
    }
    seen.add(key)

    const agentPlugin = pluginsByID.get(agentPluginID)
    if (!agentPlugin || !agentPlugin.enabledSkillNames.includes(skill.skillName)) {
      throw new Error(`Agent Plugin overlay input is unavailable: ${agentPluginID}/${skill.skillName}`)
    }

    const overlay = await resolveSkillOverlayText(skill.skillName, { turn: input.turn, rpc: input.rpc })
    if (!overlay) continue

    const relativeSkillPath = [...agentPlugin.skillsRelativePath.split('/'), skill.skillName, 'SKILL.md']
    const sourceSkillPath = join(agentPlugin.sourceRoot, ...relativeSkillPath)
    const materializedSkillPath = join(agentPlugin.materializedRoot, ...relativeSkillPath)
    writeFileSync(materializedSkillPath, composeNativeSkillFile(readFileSync(sourceSkillPath, 'utf8'), overlay), {
      mode: lstatSync(sourceSkillPath).mode & 0o777
    })
  }
}

/**
 * Uses only Codex 0.144 official app-server operations. Calling this on every
 * prepare is intentional: `plugin/install` is the idempotence contract, and
 * replaces a previously installed local package version when needed.
 */
export async function installAndTrustAgentPlugins(
  client: Pick<CodexAppServerClient, 'request'>,
  cwd: string,
  prepared: PreparedAgentPlugins
): Promise<void> {
  for (const agentPlugin of prepared.agentPlugins) {
    await client.request('plugin/install', {
      marketplacePath: prepared.marketplacePath,
      pluginName: agentPlugin.manifestName
    })
  }
  if (prepared.agentPlugins.length === 0) return

  const installed = asObject(await client.request('plugin/installed', { cwds: [cwd] }))
  const installedPlugins = arrayOfObjects(installed.marketplaces).flatMap(marketplace =>
    arrayOfObjects(marketplace.plugins)
  )
  for (const agentPlugin of prepared.agentPlugins) {
    const observation = installedPlugins.find(candidate => candidate.name === agentPlugin.manifestName)
    if (!observation || observation.installed !== true || observation.enabled !== true) {
      throw new Error(`Codex did not install and enable Agent Plugin ${agentPlugin.id}`)
    }
  }

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
}

/** Canonical package hash shared with the control-plane Library contract. */
export function computeAgentPluginContentHash(packageRoot: string): string {
  const root = resolve(packageRoot)
  if (!existsSync(root) || !lstatSync(root).isDirectory()) {
    throw new Error(`Agent Plugin package root is not a directory: ${packageRoot}`)
  }

  const files = listRegularFiles(root)
  validatePackageLimits(files)
  const chunks: Buffer[] = [CONTENT_HASH_PREFIX]
  for (const file of files) {
    const pathBytes = Buffer.from(file.relativePath, 'utf8')
    const content = readFileSync(file.absolutePath)
    const pathLength = Buffer.allocUnsafe(4)
    pathLength.writeUInt32BE(pathBytes.byteLength)
    const contentLength = Buffer.allocUnsafe(8)
    contentLength.writeBigUInt64BE(BigInt(content.byteLength))
    chunks.push(pathLength, pathBytes, contentLength, content)
  }
  return genericHash(Buffer.concat(chunks))
}

function validateAgentPluginRef(
  sourcePackagesRoot: string,
  materializedPluginsRoot: string,
  ref: AgentPluginCatalogEntry
): PreparedAgentPlugin {
  assertAgentPluginID(ref.id)
  const sourceRoot = join(sourcePackagesRoot, ref.id)
  const manifestPath = join(sourceRoot, '.codex-plugin', 'plugin.json')
  let manifest: Record<string, unknown>
  try {
    manifest = asObject(JSON.parse(readFileSync(manifestPath, 'utf8')))
  } catch (error) {
    throw new Error(
      `invalid Agent Plugin manifest for ${ref.id}: ${error instanceof Error ? error.message : String(error)}`
    )
  }

  const manifestName = requiredString(manifest.name, `Agent Plugin ${ref.id} manifest name`)
  const version = requiredString(manifest.version, `Agent Plugin ${ref.id} manifest version`)
  const skillsRelativePath = manifestDirectoryPath(
    sourceRoot,
    manifest.skills,
    `Agent Plugin ${ref.id} manifest skills`
  )
  if (manifestName !== ref.id) throw new Error(`Agent Plugin id/manifest name mismatch: ${ref.id}/${manifestName}`)
  if (version !== ref.version) {
    throw new Error(`Agent Plugin version mismatch for ${ref.id}: ${version} != ${ref.version}`)
  }

  const contentHash = computeAgentPluginContentHash(sourceRoot)
  if (contentHash !== ref.contentHash) {
    throw new Error(`Agent Plugin content hash mismatch for ${ref.id}: ${contentHash} != ${ref.contentHash}`)
  }

  const materializedRoot = join(materializedPluginsRoot, ref.id)
  const memberSkillNames = agentPluginSkillDirectoryNames(sourceRoot, skillsRelativePath)
  const enabledSkillNames = ref.skills.map(skill => skill.catalogName).sort(compareCodePoints)
  assertEnabledSkillSelection(ref, memberSkillNames, manifestName)
  const enabledCodexSkillNames = ref.skills.map(skill => skill.codexName).sort(compareCodePoints)
  return {
    ...ref,
    manifestName,
    skillsRelativePath,
    sourceRoot,
    materializedRoot,
    memberSkillNames,
    enabledSkillNames,
    enabledCodexSkillNames
  }
}

function initializeJobProjectAtomically(
  projectRoot: string,
  agentPlugins: PreparedAgentPlugin[],
  agentsContent: string
): void {
  const parent = dirname(projectRoot)
  mkdirSync(parent, { recursive: true })
  const stagedRoot = join(parent, `.project-init-${crypto.randomUUID()}`)
  try {
    mkdirSync(stagedRoot, { mode: 0o700 })
    const stagedPluginsRoot = join(stagedRoot, 'plugins')
    mkdirSync(stagedPluginsRoot)
    for (const agentPlugin of agentPlugins) {
      copyDirectoryStrict(agentPlugin.sourceRoot, join(stagedPluginsRoot, agentPlugin.id))
    }
    initializeWorkspaceTemplates(stagedRoot, agentPlugins)
    appendProjectAgents(stagedRoot, agentsContent)
    writeMarketplace(stagedRoot, agentPlugins)

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

function refreshAgentPluginPackages(pluginsRoot: string, agentPlugins: PreparedAgentPlugin[]): void {
  rmSync(pluginsRoot, { recursive: true, force: true })
  mkdirSync(pluginsRoot, { recursive: true })
  for (const agentPlugin of agentPlugins) {
    copyDirectoryStrict(agentPlugin.sourceRoot, join(pluginsRoot, agentPlugin.id))
  }
}

function appendProjectAgents(projectRoot: string, content: string): void {
  const guidance = content.trim()
  if (!guidance) throw new Error('Background agent Job guidance is required during project initialization')

  const path = join(projectRoot, 'AGENTS.md')
  const existing = existsSync(path) ? readFileSync(path, 'utf8').trimEnd() : ''
  writeFileSync(path, `${existing ? `${existing}\n\n` : ''}${guidance}\n`, { mode: 0o600 })
}

function writeMarketplace(projectRoot: string, agentPlugins: PreparedAgentPlugin[]): string {
  const marketplacePath = join(projectRoot, '.agents', 'plugins', 'marketplace.json')
  atomicWriteJSON(marketplacePath, {
    name: MARKETPLACE_NAME,
    plugins: agentPlugins.map(agentPlugin => ({
      name: agentPlugin.manifestName,
      source: { source: 'local', path: `./plugins/${agentPlugin.id}` },
      policy: { installation: 'AVAILABLE', authentication: 'ON_INSTALL' },
      category: 'Developer Tools'
    }))
  })
  return marketplacePath
}

function initializeWorkspaceTemplates(projectRoot: string, agentPlugins: PreparedAgentPlugin[]): void {
  const occupiedFiles = new Map<string, string>()

  for (const agentPlugin of agentPlugins) {
    const templateRoot = join(agentPlugin.sourceRoot, 'workspace-template')
    if (!existsSync(templateRoot)) continue
    if (!lstatSync(templateRoot).isDirectory()) {
      throw new Error(`Agent Plugin workspace-template is not a directory: ${agentPlugin.id}`)
    }

    for (const entry of listTemplateEntries(templateRoot)) {
      const target = join(projectRoot, ...entry.relativePath.split('/'))
      if (entry.kind === 'directory') {
        mkdirSync(target, { recursive: true })
        continue
      }

      const owner = occupiedFiles.get(entry.relativePath)
      if (owner) {
        throw new Error(
          `Agent Plugin workspace template file conflict at ${entry.relativePath}: ${owner}, ${agentPlugin.id}`
        )
      }
      if (existsSync(target)) {
        throw new Error(
          `Agent Plugin workspace template conflicts with existing Job project file: ${entry.relativePath}`
        )
      }
      occupiedFiles.set(entry.relativePath, agentPlugin.id)
      mkdirSync(dirname(target), { recursive: true })
      copyFileSync(entry.absolutePath, target)
      chmodSync(target, lstatSync(entry.absolutePath).mode & 0o777)
    }
  }
}

function copyDirectoryStrict(sourceRoot: string, targetRoot: string): void {
  if (existsSync(targetRoot)) throw new Error(`Agent Plugin materialization target already exists: ${targetRoot}`)
  mkdirSync(targetRoot, { recursive: true })
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

function listRegularFiles(root: string): Array<{ relativePath: string; absolutePath: string; byteSize: number }> {
  return listTemplateEntries(root)
    .filter((entry): entry is { kind: 'file'; relativePath: string; absolutePath: string } => entry.kind === 'file')
    .map(entry => ({ ...entry, byteSize: lstatSync(entry.absolutePath).size }))
    .sort((left, right) => Buffer.from(left.relativePath).compare(Buffer.from(right.relativePath)))
}

function validatePackageLimits(files: Array<{ relativePath: string; byteSize: number }>): void {
  if (files.length > MAX_PACKAGE_FILES) {
    throw new Error(`Agent Plugin package exceeds ${MAX_PACKAGE_FILES} regular files`)
  }
  let totalBytes = 0
  for (const file of files) {
    const pathBytes = Buffer.byteLength(file.relativePath, 'utf8')
    if (pathBytes > MAX_PACKAGE_PATH_BYTES) {
      throw new Error(`Agent Plugin package path exceeds ${MAX_PACKAGE_PATH_BYTES} bytes: ${file.relativePath}`)
    }
    if (file.byteSize > MAX_PACKAGE_FILE_BYTES) {
      throw new Error(`Agent Plugin package file exceeds ${MAX_PACKAGE_FILE_BYTES} bytes: ${file.relativePath}`)
    }
    totalBytes += file.byteSize
    if (totalBytes > MAX_PACKAGE_CONTENT_BYTES) {
      throw new Error(`Agent Plugin package content exceeds ${MAX_PACKAGE_CONTENT_BYTES} bytes`)
    }
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

function agentPluginSkillDirectoryNames(packageRoot: string, skillsRelativePath: string): string[] {
  const skillsRoot = join(packageRoot, ...skillsRelativePath.split('/'))
  return readdirSync(skillsRoot, { withFileTypes: true })
    .filter(entry => entry.isDirectory() && existsSync(join(skillsRoot, entry.name, 'SKILL.md')))
    .map(entry => entry.name)
    .sort(compareCodePoints)
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

function assertEnabledSkillSelection(
  ref: AgentPluginCatalogEntry,
  memberSkillNames: string[],
  manifestName: string
): void {
  const enabledNames = new Set(ref.skills.map(skill => skill.catalogName))
  if (enabledNames.size !== ref.skills.length) {
    throw new Error(`Agent Plugin ${ref.id} catalog contains duplicate Skill names`)
  }
  const memberNames = new Set(memberSkillNames)
  const unknown = [...enabledNames].filter(name => !memberNames.has(name)).sort(compareCodePoints)
  if (unknown.length > 0) {
    throw new Error(`Agent Plugin ${ref.id} catalog enables unknown Skills: ${unknown.join(', ')}`)
  }

  const invalidCodexNames = ref.skills
    .filter(skill => skill.codexName !== `${manifestName}:${skill.catalogName}`)
    .map(skill => skill.codexName)
    .sort(compareCodePoints)
  if (invalidCodexNames.length > 0) {
    throw new Error(`Agent Plugin ${ref.id} catalog has invalid Codex Skill names: ${invalidCodexNames.join(', ')}`)
  }
}

async function selectedPluginHooks(
  client: Pick<CodexAppServerClient, 'request'>,
  cwd: string,
  prepared: PreparedAgentPlugins
): Promise<Array<{ key: string; currentHash: string; trustStatus?: string }>> {
  const response = asObject(await client.request('hooks/list', { cwds: [cwd] }))
  const expectedPluginIDs = new Set(
    prepared.agentPlugins.map(agentPlugin => `${agentPlugin.manifestName}@${prepared.marketplaceName}`)
  )
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

function atomicWriteJSON(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.tmp-${process.pid}-${crypto.randomUUID()}`
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
  renameSync(temporary, path)
  chmodSync(path, 0o600)
}

function arrayOfObjects(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value) ? value.map(asObject) : []
}

function asObject(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : {}
}

function requiredString(value: unknown, label: string): string {
  if (typeof value !== 'string' || value.length === 0) throw new Error(`${label} is required`)
  return value
}

function compareCodePoints(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}

function compareAgentPluginSkills(left: RuntimeSkillSummary, right: RuntimeSkillSummary): number {
  return (
    compareCodePoints(left.agentPluginId, right.agentPluginId) || compareCodePoints(left.skillName, right.skillName)
  )
}
