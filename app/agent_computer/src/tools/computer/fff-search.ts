import { ms } from '@agentbull/active-support'
import type { FileFinder, GrepCursor } from '@ff-labs/fff-bun'
import { realpathSync, statSync } from 'node:fs'
import { normalize, relative, resolve } from 'node:path'
import { pathIsWithin } from '../../core/path-boundary'

/**
 * The fff engine seam for the `find` and `grep` tools.
 *
 * One native fff index runs in the Worker process per search root. The pool
 * below keeps a small number of warm indexes alive across turns: the current
 * workspace plus on-demand roots elsewhere inside the Agent Home. The pool is
 * rebuildable Worker-local state; losing it only costs one rescan.
 *
 * Boundary rule: every search root must realpath-resolve inside the Agent
 * Home. That keeps search results consistent with the bubblewrap view the
 * other computer tools expose — the two filesystem views agree exactly on the
 * Agent Home subtree.
 */

const SCAN_WAIT_MS = ms('15s')
const IDLE_TTL_MS = ms('5m')
const MAX_FINDERS = 4
const MAX_CURSORS = 200
export const GREP_TIME_BUDGET_MS = ms('10s')
/** Worker-owned runtime data under the Agent Home that default searches skip. */
export const AGENT_RUNTIME_DIRNAME = '.ankole'

type FffModule = typeof import('@ff-labs/fff-bun')

let fffModulePromise: Promise<FffModule> | undefined

function loadFff(): Promise<FffModule> {
  fffModulePromise ??= import('@ff-labs/fff-bun')
  return fffModulePromise
}

interface FinderEntry {
  root: string
  finder: FileFinder
  lastUsed: number
}

export interface AcquiredFinder {
  finder: FileFinder
  /** Realpath the finder indexes; result paths are relative to it. */
  root: string
}

export interface GrepCursorState {
  cursor: GrepCursor
  root: string
  query: string
  mode: 'plain' | 'regex' | 'fuzzy'
  smartCase: boolean
  context: number
  pageSize: number
}

export interface FindCursorState {
  root: string
  query: string
  pattern: string
  pageSize: number
  /** Item offset of the next page: `fileSearch`'s `pageIndex` counts items, not pages. */
  nextOffset: number
}

/**
 * Owns the warm fff finders and the pagination cursors they hand out.
 *
 * Concurrent `acquire()` calls for one root share one in-flight creation so
 * the native layer never races two scans of the same tree.
 */
export class FffSearchRuntime {
  private entries: FinderEntry[] = []
  private pending = new Map<string, Promise<FinderEntry>>()
  private grepCursors = new Map<string, GrepCursorState>()
  private findCursors = new Map<string, FindCursorState>()
  private cursorCounter = 0

  /**
   * Resolve a warm finder for `root` (a realpath). With `covering` an existing
   * finder indexing an ancestor of `root` is reused; results are then relative
   * to the returned `root`, not the requested one.
   */
  async acquire(root: string, opts?: { covering?: boolean }): Promise<AcquiredFinder> {
    this.sweepIdle()

    let best: FinderEntry | undefined
    for (const entry of this.entries) {
      if (entry.finder.isDestroyed) continue
      if (opts?.covering ? !rootCovers(entry.root, root) : entry.root !== root) continue
      if (!best || entry.root.length > best.root.length) best = entry
    }
    if (best) {
      best.lastUsed = Date.now()
      return { finder: best.finder, root: best.root }
    }

    const inflight = this.pending.get(root)
    if (inflight) {
      const entry = await inflight
      entry.lastUsed = Date.now()
      return { finder: entry.finder, root: entry.root }
    }

    const creation = this.create(root).finally(() => {
      this.pending.delete(root)
    })
    this.pending.set(root, creation)
    const entry = await creation
    return { finder: entry.finder, root: entry.root }
  }

  /**
   * Warm the index for a root without blocking the caller: rescan a warm
   * finder (fff throttles repeats), or start the first scan in the background.
   */
  prewarm(root: string): void {
    void (async () => {
      try {
        const real = realpathSync(resolve(root))
        const existing = this.entries.find(entry => entry.root === real && !entry.finder.isDestroyed)
        if (existing) {
          existing.finder.scanFiles()
          return
        }
        await this.acquire(real)
      } catch {
        // Prewarm is best-effort; the first search surfaces a real failure.
      }
    })()
  }

  storeGrepCursor(state: GrepCursorState): string {
    const id = `g${++this.cursorCounter}`
    this.grepCursors.set(id, state)
    trimOldest(this.grepCursors)
    return id
  }

  getGrepCursor(id: string): GrepCursorState | undefined {
    return this.grepCursors.get(id)
  }

  storeFindCursor(state: FindCursorState): string {
    const id = `f${++this.cursorCounter}`
    this.findCursors.set(id, state)
    trimOldest(this.findCursors)
    return id
  }

  getFindCursor(id: string): FindCursorState | undefined {
    return this.findCursors.get(id)
  }

  destroyAll(): void {
    for (const entry of this.entries) {
      if (!entry.finder.isDestroyed) entry.finder.destroy()
    }
    this.entries = []
    this.pending.clear()
    this.grepCursors.clear()
    this.findCursors.clear()
  }

  private async create(root: string): Promise<FinderEntry> {
    if (this.entries.length >= MAX_FINDERS) {
      let oldest = this.entries[0]!
      for (const entry of this.entries) if (entry.lastUsed < oldest.lastUsed) oldest = entry
      if (!oldest.finder.isDestroyed) oldest.finder.destroy()
      this.entries = this.entries.filter(entry => entry !== oldest)
    }

    const mod = await loadFff()
    // No frecency/history databases: the Agent Home lives on a shared network
    // filesystem where LMDB is unsafe. Ranking still uses fuzzy score,
    // modification recency, and git status.
    const created = mod.FileFinder.create({ basePath: root, aiMode: true })
    if (!created.ok) {
      throw new Error(`file search engine failed to start for ${root}: ${created.error}`)
    }
    // Bounds first-search latency; an unfinished scan surfaces per query
    // through `isScanning()` notices, not as a failure.
    await created.value.waitForScan(SCAN_WAIT_MS)

    const entry: FinderEntry = { root, finder: created.value, lastUsed: Date.now() }
    this.entries.push(entry)
    return entry
  }

  private sweepIdle(): void {
    const now = Date.now()
    const kept: FinderEntry[] = []
    for (const entry of this.entries) {
      if (entry.finder.isDestroyed) continue
      if (now - entry.lastUsed > IDLE_TTL_MS) {
        entry.finder.destroy()
        continue
      }
      kept.push(entry)
    }
    this.entries = kept
  }
}

/** The process-wide runtime shared across turns so warm indexes survive. */
export const fffSearchRuntime = new FffSearchRuntime()

function trimOldest(map: Map<string, unknown>): void {
  while (map.size > MAX_CURSORS) {
    const first = map.keys().next().value
    if (first === undefined) return
    map.delete(first)
  }
}

export function rootCovers(root: string, target: string): boolean {
  if (root === target) return true
  const prefix = root.endsWith('/') ? root : `${root}/`
  return target.startsWith(prefix)
}

export type SearchTarget =
  | {
      ok: true
      /** Realpath of the search root to acquire a finder for. */
      root: string
      /** Path constraint relative to `root`, already normalized for the query. */
      constraint?: string
    }
  | { ok: false; message: string }

export interface SearchScope {
  agentHome: string
  workspaceRoot: string
}

/**
 * Map a model-supplied `path` argument onto a finder root plus an in-index
 * constraint. Glob and not-yet-existing segments stay in the constraint; the
 * root is the deepest existing directory. Paths inside the current workspace
 * fold onto the workspace finder so their results stay workspace-relative.
 */
export function resolveSearchTarget(scope: SearchScope, rawPath: string | undefined): SearchTarget {
  const homeReal = realpathSync(resolve(scope.agentHome))
  const workspaceReal = realpathSync(resolve(scope.workspaceRoot))

  if (rawPath === undefined || rawPath.trim() === '') {
    return { ok: true, root: workspaceReal }
  }

  const trimmed = rawPath.trim()
  const expanded =
    trimmed === '~'
      ? scope.agentHome
      : trimmed.startsWith('~/')
        ? resolve(scope.agentHome, trimmed.slice(2))
        : resolve(scope.workspaceRoot, trimmed)

  const split = splitExistingRoot(expanded)
  if (!split) return { ok: false, message: `Path not found: ${trimmed}` }

  let rootReal: string
  try {
    rootReal = realpathSync(split.root)
  } catch {
    return { ok: false, message: `Path not found: ${trimmed}` }
  }
  if (!pathIsWithin(homeReal, rootReal)) {
    return {
      ok: false,
      message: `Path is outside the agent home: ${trimmed}. find/grep/ls cover ~ only; use the command tool for other locations.`
    }
  }

  if (pathIsWithin(workspaceReal, rootReal)) {
    const rebase = relative(workspaceReal, rootReal)
    const constraint = normalizeConstraint(joinConstraint(rebase, split.suffix))
    return { ok: true, root: workspaceReal, ...(constraint ? { constraint } : {}) }
  }

  const constraint = normalizeConstraint(split.suffix)
  return { ok: true, root: rootReal, ...(constraint ? { constraint } : {}) }
}

/**
 * Split an absolute path into its deepest existing directory and the
 * remainder. Glob segments and missing tails both belong to the remainder, so
 * a partially wrong path still resolves to a usable search root. A path that
 * lands on a file searches the parent directory constrained to that file.
 */
function splitExistingRoot(absPath: string): { root: string; suffix: string } | undefined {
  const trimmed = normalize(absPath).replace(/\/+$/, '') || '/'
  const parts = trimmed.split('/')
  const firstGlob = parts.findIndex(part => /[*?[{]/.test(part))
  const boundary = firstGlob === -1 ? parts.length : firstGlob

  for (let index = boundary; index > 1; index--) {
    const candidate = parts.slice(0, index).join('/') || '/'
    let stat
    try {
      stat = statSync(candidate)
    } catch {
      continue
    }
    if (stat.isFile()) {
      return { root: parts.slice(0, index - 1).join('/') || '/', suffix: parts.slice(index - 1).join('/') }
    }
    return { root: candidate, suffix: parts.slice(index).join('/') }
  }
  return undefined
}

function joinConstraint(prefix: string, suffix: string): string {
  return [prefix, suffix].filter(Boolean).join('/')
}

/**
 * Normalize one path constraint into the shape the fff query parser reads:
 * bare directories gain a trailing `/`, trivial recursive globs collapse to
 * the directory prefix, and no-op constraints drop out entirely.
 */
export function normalizeConstraint(raw: string): string | undefined {
  let trimmed = raw.trim()
  if (!trimmed || trimmed === '.' || trimmed === './') return undefined
  if (trimmed.startsWith('./')) trimmed = trimmed.slice(2)
  if (trimmed === '**' || trimmed === '**/' || trimmed === '**/*') return undefined

  // The glob matcher can treat `dir/**` as empty while the tool contract says
  // "inside this directory"; collapse it to the directory-prefix constraint.
  const recursiveDir = trimmed.match(/^(.*)\/\*\*(?:\/\*)?$/)
  if (recursiveDir) {
    const dir = recursiveDir[1]
    if (dir && !/[*?[{]/.test(dir)) return `${dir}/`
  }

  if (trimmed.startsWith('/') || trimmed.endsWith('/')) return trimmed
  if (/[*?[{]/.test(trimmed)) return trimmed
  const lastSegment = trimmed.split('/').pop() ?? ''
  if (/\.[a-zA-Z][a-zA-Z0-9]{0,9}$/.test(lastSegment)) return trimmed
  return `${trimmed}/`
}

/**
 * Normalize `exclude` values into `!` constraint tokens. Callers may pass one
 * string with comma or space separators, an array, and already-negated forms.
 */
export function normalizeExcludes(exclude: string | string[] | undefined): string[] {
  if (!exclude) return []
  const list = Array.isArray(exclude) ? exclude : [exclude]
  const out: string[] = []
  for (const raw of list) {
    for (const part of raw.split(/[,\s]+/)) {
      const trimmed = part.trim()
      if (!trimmed) continue
      const stripped = trimmed.startsWith('!') ? trimmed.slice(1) : trimmed
      const normalized = normalizeConstraint(stripped)
      if (normalized) out.push(`!${normalized}`)
    }
  }
  return out
}

/** Assemble the query string the fff parser splits back into constraints + pattern. */
export function buildSearchQuery(input: {
  constraint: string | undefined
  excludes: string[]
  pattern: string
}): string {
  const parts: string[] = []
  if (input.constraint) parts.push(input.constraint)
  parts.push(...input.excludes)
  const pattern = input.pattern.trim()
  if (pattern) parts.push(pattern)
  return parts.join(' ')
}

const HOT_FRECENCY = 25
const WARM_FRECENCY = 20

/**
 * At most one tag per result line so output stays scannable. Git-dirty (the
 * file is changing right now) outranks frecency (historically often touched).
 */
export function fileAnnotation(item: {
  gitStatus?: string
  totalFrecencyScore?: number
  accessFrecencyScore?: number
}): string {
  const git = item.gitStatus
  if (git && git !== 'clean' && git !== 'unknown' && git !== '') {
    return `  [${git} in git]`
  }
  const frecency = item.totalFrecencyScore ?? item.accessFrecencyScore ?? 0
  if (frecency >= HOT_FRECENCY) return '  [VERY often touched file]'
  if (frecency >= WARM_FRECENCY) return '  [often touched file]'
  return ''
}

export const SEARCH_MAX_LINE_LENGTH = 500

/** Clip one match or context line so grep output stays compact. */
export function clipSearchLine(line: string): { text: string; wasClipped: boolean } {
  const trimmed = line.trimEnd()
  if (trimmed.length <= SEARCH_MAX_LINE_LENGTH) return { text: trimmed, wasClipped: false }
  return { text: `${trimmed.slice(0, SEARCH_MAX_LINE_LENGTH)}...`, wasClipped: true }
}

/** Render a result path the way the model can feed straight back into read_file. */
export function displayPath(root: string, workspaceReal: string, relativePath: string): string {
  return root === workspaceReal ? relativePath : `${root}/${relativePath}`
}

export function scanNotice(finder: FileFinder): string | undefined {
  return finder.isScanning() ? 'Index scan still running; results may be incomplete' : undefined
}
