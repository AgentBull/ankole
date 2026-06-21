import type { BullXPlugin } from '@agentbull/bullx-sdk/plugins'
import { readdir, readFile, realpath } from 'node:fs/promises'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

export interface PluginDiscoveryOptions {
  pluginRoots?: readonly string[]
  /**
   * Roots whose plugins are enabled by default — first-party "internal" plugins
   * (e.g. `internals/plugins`). Distinct from `pluginRoots`, whose plugins stay
   * disabled unless listed in `defaultEnabledPluginIds` or enabled by override.
   */
  autoEnabledPluginRoots?: readonly string[]
}

/** Discovery result that also reports which plugins came from auto-enabled roots. */
export interface DiscoveredPlugins {
  plugins: BullXPlugin[]
  autoEnabledPluginIds: string[]
}

interface PluginPackageJson {
  bullx?: {
    plugin?: string
  }
  exports?: unknown
}

const fallbackPluginEntries = ['src/index.ts', 'index.ts', 'dist/index.js', 'index.js']

export class PluginDiscoveryError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'PluginDiscoveryError'
  }
}

/**
 * Discovers loadable local plugins and returns only plugin objects.
 */
export async function discoverLocalPlugins(options: PluginDiscoveryOptions = {}): Promise<BullXPlugin[]> {
  return (await discoverLocalPluginsDetailed(options)).plugins
}

/**
 * Discovers local plugins and remembers which ones came from auto-enabled roots.
 *
 * Entries are canonicalized before import so the same plugin reached through
 * symlinks or overlapping roots is loaded once and classified by the first root
 * that discovers it.
 */
export async function discoverLocalPluginsDetailed(options: PluginDiscoveryOptions = {}): Promise<DiscoveredPlugins> {
  const plugins: BullXPlugin[] = []
  const autoEnabledPluginIds: string[] = []
  const seen = new Set<string>()

  const collect = async (roots: readonly string[], autoEnabled: boolean): Promise<void> => {
    for (const entryPath of await discoverPluginEntryPaths(roots)) {
      const canonical = await canonicalPath(entryPath)
      if (seen.has(canonical)) continue
      seen.add(canonical)
      const module = (await import(pathToFileURL(entryPath).href)) as Record<string, unknown>
      const plugin = readPluginExport(module, entryPath)
      plugins.push(plugin)
      if (autoEnabled) autoEnabledPluginIds.push(plugin.metadata.id)
    }
  }

  await collect(options.pluginRoots ?? defaultPluginRoots(), false)
  await collect(options.autoEnabledPluginRoots ?? defaultAutoEnabledPluginRoots(), true)

  return { plugins, autoEnabledPluginIds }
}

/**
 * Lists plugin entry files under the configured roots.
 */
export async function discoverPluginEntryPaths(pluginRoots: readonly string[]): Promise<string[]> {
  const entries = new Map<string, string>()

  for (const root of uniquePaths(pluginRoots)) {
    for (const entryPath of await discoverRootPluginEntries(root)) {
      entries.set(await canonicalPath(entryPath), entryPath)
    }
  }

  return [...entries.values()]
}

/**
 * Returns operator-configured plugin roots.
 */
export function defaultPluginRoots(): string[] {
  return uniquePaths(envPluginRoots())
}

const DEFAULT_INTERNAL_PLUGIN_ROOT = '../internals/plugins'

/**
 * Auto-enabled (first-party) plugin roots. Defaults to `../internals/plugins`
 * relative to the app working dir — absent in open-source checkouts, which is a
 * safe no-op. Inert under `bun test` (NODE_ENV==='test') unless `INTERNAL_PLUGIN_DIR`
 * is set explicitly, so suites stay hermetic.
 */
export function defaultAutoEnabledPluginRoots(): string[] {
  const configured = Bun.env.INTERNAL_PLUGIN_DIR?.trim()
  if (configured) {
    return uniquePaths(
      configured
        .split(',')
        .map(root => root.trim())
        .filter(root => root.length > 0)
    )
  }
  if (Bun.env.NODE_ENV === 'test') return []
  return uniquePaths([DEFAULT_INTERNAL_PLUGIN_ROOT])
}

async function discoverRootPluginEntries(root: string): Promise<string[]> {
  const rootEntry = await resolvePluginEntry(root)
  if (rootEntry) return [rootEntry]

  let children
  try {
    children = await readdir(root, { withFileTypes: true })
  } catch {
    return []
  }

  const entries: string[] = []
  for (const child of children) {
    if (!child.isDirectory() || child.name.startsWith('.')) continue

    const entry = await resolvePluginEntry(path.join(root, child.name))
    if (entry) entries.push(entry)
  }

  return entries.sort()
}

async function resolvePluginEntry(pluginDir: string): Promise<string | undefined> {
  const explicitEntry = await explicitPluginEntry(pluginDir)
  if (explicitEntry) return explicitEntry

  for (const relativeEntry of fallbackPluginEntries) {
    const candidate = path.join(pluginDir, relativeEntry)
    if (await fileExists(candidate)) return candidate
  }
}

async function explicitPluginEntry(pluginDir: string): Promise<string | undefined> {
  const packageJsonPath = path.join(pluginDir, 'package.json')
  if (!(await fileExists(packageJsonPath))) return undefined

  let parsed: PluginPackageJson
  try {
    parsed = JSON.parse(await readFile(packageJsonPath, 'utf8')) as PluginPackageJson
  } catch (error) {
    throw new PluginDiscoveryError(`Invalid plugin package.json: ${packageJsonPath}`, { cause: error })
  }

  const entry = parsed.bullx?.plugin ?? packageExportEntry(parsed.exports)
  if (!entry) return undefined

  const entryPath = path.resolve(pluginDir, entry)
  if (!(await fileExists(entryPath))) throw new PluginDiscoveryError(`Plugin entry does not exist: ${entryPath}`)

  return entryPath
}

function packageExportEntry(exportsField: unknown): string | undefined {
  if (typeof exportsField === 'string') return exportsField
  if (typeof exportsField !== 'object' || exportsField === null) return undefined

  const rootExport = (exportsField as Record<string, unknown>)['.']
  if (typeof rootExport === 'string') return rootExport
  if (typeof rootExport !== 'object' || rootExport === null) return undefined

  const objectExport = rootExport as Record<string, unknown>
  const entry = objectExport.import ?? objectExport.default
  return typeof entry === 'string' ? entry : undefined
}

function readPluginExport(module: Record<string, unknown>, entryPath: string): BullXPlugin {
  const plugin = [module.default, module.bullxPlugin, module.plugin, ...Object.values(module)].find(isBullXPlugin)
  if (!plugin) throw new PluginDiscoveryError(`Plugin entry did not export a BullX plugin: ${entryPath}`)

  return plugin
}

function isBullXPlugin(value: unknown): value is BullXPlugin {
  return (
    typeof value === 'object' &&
    value !== null &&
    'metadata' in value &&
    typeof (value as BullXPlugin).metadata === 'object' &&
    (value as BullXPlugin).metadata !== null
  )
}

async function fileExists(filePath: string): Promise<boolean> {
  return Bun.file(filePath).exists()
}

async function canonicalPath(filePath: string): Promise<string> {
  try {
    return await realpath(filePath)
  } catch {
    return path.resolve(filePath)
  }
}

function envPluginRoots(): string[] {
  const pluginDir = Bun.env.PLUGIN_DIR?.trim()
  return pluginDir ? [pluginDir] : []
}

function uniquePaths(paths: readonly string[]): string[] {
  const seen = new Set<string>()
  const result: string[] = []

  for (const value of paths) {
    const normalized = path.resolve(value)
    if (seen.has(normalized)) continue

    seen.add(normalized)
    result.push(normalized)
  }

  return result
}
