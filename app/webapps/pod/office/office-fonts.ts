import { useEffect, useMemo, useState } from 'react'
import { staticAssetBase, staticAssetURL } from '../../common/browser-context'
import type { OfficeSnapshotBase, OfficeSyncEngine } from './office-collaboration'

export type OfficeFontManifestEntry = {
  family: string
  aliases?: string[]
  file: string
  style?: string
  weight?: number | [number, number]
  italic?: boolean
  sha256?: string
  bytes?: number
}

export type OfficeFontRequests = {
  substitutedFamilies: readonly string[]
  missingGlyphFamilies: readonly string[]
}

export type OfficeFontStatus = {
  epoch: number
  fontsReady: boolean
  waitForFonts: () => Promise<void>
}

export type OfficeFontModel<TSnapshot extends OfficeSnapshotBase> = {
  updateSelection: (
    task: (engine: OfficeSyncEngine<TSnapshot>) => Promise<{ snapshot: TSnapshot }>
  ) => Promise<TSnapshot | undefined>
}

export type OfficeFontOptions = {
  documentLoaded?: boolean
  initialGateTimeoutMs?: number
  exportWaitTimeoutMs?: number
  retryDelayMs?: number
}

type OfficeFontManifest = {
  fonts?: OfficeFontManifestEntry[]
}

type ManifestLookup = {
  ok: boolean
  entries: OfficeFontManifestEntry[]
}

const DEFERRED_GENERIC_HAN_FAMILY = 'ibm plex sans sc'
const INITIAL_FONTS_GATE_TIMEOUT_MS = 3_000
const EXPORT_FONTS_WAIT_TIMEOUT_MS = 8_000
const TRANSIENT_RETRY_DELAY_MS = 250
const MAX_TRANSIENT_RETRIES = 1

/**
 * Canonical CJK `entry.family` targets in `/fonts/office/manifest.json`.
 * All alias-to-family mappings live in the site font manifest (`fetch-office-fonts.mjs`) so
 * browser font selection and server/Rust catalogs share a single source of truth.
 */
const CANONICAL_CJK_FAMILIES = new Set([
  'ibm plex sans sc',
  '寒蝉锦书宋',
  'lxgw wenkai gb',
  'ibmplexmonoschalf',
  'noto sans tc',
  'noto serif tc',
  'noto sans jp',
  'noto serif jp',
  'noto sans kr',
  'noto serif kr'
])

const HANGUL_RE = /[\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]/
const KANA_RE = /[\u3040-\u30ff\uff66-\uff9f]/

let cachedFetch: typeof fetch | undefined
let manifestPromise: Promise<ManifestLookup> | undefined
let cachedManifestEntries: OfficeFontManifestEntry[] | undefined
let cachedManifestFamilyLookup: ReadonlyMap<string, string> | undefined
const blobCache = new Map<string, Promise<Uint8Array | undefined>>()

function syncCacheToFetch(): void {
  const currentFetch = typeof fetch === 'function' ? fetch : undefined
  if (cachedFetch !== currentFetch) {
    cachedFetch = currentFetch
    manifestPromise = undefined
    cachedManifestEntries = undefined
    cachedManifestFamilyLookup = undefined
    blobCache.clear()
  }
}

function normalizeFamily(name: string): string {
  return name.trim().toLowerCase()
}

function buildManifestFamilyLookup(entries: readonly OfficeFontManifestEntry[]): ReadonlyMap<string, string> {
  const map = new Map<string, string>()
  for (const entry of entries) {
    const canonical = normalizeFamily(entry.family)
    if (!canonical) continue
    map.set(canonical, canonical)
    for (const alias of entry.aliases ?? []) {
      const normAlias = normalizeFamily(alias)
      if (normAlias && !map.has(normAlias)) {
        map.set(normAlias, canonical)
      }
    }
  }
  return map
}

function inferUnknownNonAsciiFallback(normalized: string): string | undefined {
  let hasNonAscii = false
  for (let i = 0; i < normalized.length; i++) {
    if (normalized.charCodeAt(i) > 0x7f) {
      hasNonAscii = true
      break
    }
  }
  if (!hasNonAscii) return undefined
  if (HANGUL_RE.test(normalized)) return 'noto sans kr'
  if (KANA_RE.test(normalized)) return 'noto sans jp'
  return DEFERRED_GENERIC_HAN_FAMILY
}

function isCjkFamilyRequest(normalized: string, manifestLookup?: ReadonlyMap<string, string>): boolean {
  if (CANONICAL_CJK_FAMILIES.has(normalized)) return true
  const canonical = manifestLookup?.get(normalized) ?? inferUnknownNonAsciiFallback(normalized)
  return canonical !== undefined && CANONICAL_CJK_FAMILIES.has(canonical)
}

/**
 * Computes normalized, unattempted font family names to fetch on the current pass.
 *
 * When a document declares a specific CJK family in `substitutedFamilies` (such as `华文楷体`,
 * `STXingkai`, or `宋体`), the engine also emits `IBM Plex Sans SC` in `missingGlyphFamilies`
 * before any CJK face has loaded. Deferring that generic `IBM Plex Sans SC` request while an
 * unattempted CJK substitution is pending avoids downloading 32 MiB of redundant sans weights on
 * pure Song/Kai documents; if any character remains uncovered after Pass 1 registers the
 * substituted family, Pass 2 fetches `IBM Plex Sans SC` automatically.
 */
export function selectPendingFontFamilies(
  requests: OfficeFontRequests | readonly string[],
  attempted: ReadonlySet<string>,
  manifestEntries?: readonly OfficeFontManifestEntry[]
): string[] {
  syncCacheToFetch()
  if (Array.isArray(requests)) {
    const out = new Set<string>()
    for (const raw of requests) {
      const norm = normalizeFamily(raw)
      if (norm && !attempted.has(norm)) out.add(norm)
    }
    return [...out]
  }

  const lookup = manifestEntries ? buildManifestFamilyLookup(manifestEntries) : cachedManifestFamilyLookup
  const structured = requests as OfficeFontRequests
  const unattemptedSubs = new Set<string>()
  let hasUnattemptedCjkSub = false
  for (const raw of structured.substitutedFamilies) {
    const norm = normalizeFamily(raw)
    if (!norm || attempted.has(norm)) continue
    unattemptedSubs.add(norm)
    if (isCjkFamilyRequest(norm, lookup)) {
      hasUnattemptedCjkSub = true
    }
  }

  const out = new Set<string>(unattemptedSubs)
  for (const raw of structured.missingGlyphFamilies) {
    const norm = normalizeFamily(raw)
    if (!norm || attempted.has(norm)) continue
    if (hasUnattemptedCjkSub && norm === DEFERRED_GENERIC_HAN_FAMILY && !unattemptedSubs.has(norm)) {
      continue
    }
    out.add(norm)
  }
  return [...out]
}

async function loadManifest(): Promise<ManifestLookup> {
  if (typeof fetch !== 'function') return { ok: true, entries: [] }
  try {
    const credentials: RequestCredentials = staticAssetBase() ? 'omit' : 'same-origin'
    const res = await fetch(staticAssetURL('/fonts/office/manifest.json'), { credentials })
    if (res.status === 404) return { ok: true, entries: [] }
    if (!res.ok) return { ok: false, entries: [] }
    const body = (await res.json()) as OfficeFontManifest
    return {
      ok: true,
      entries: Array.isArray(body?.fonts) ? body.fonts : []
    }
  } catch {
    return { ok: false, entries: [] }
  }
}

function fetchManifest(): Promise<ManifestLookup> {
  syncCacheToFetch()
  if (!manifestPromise) {
    const request: Promise<ManifestLookup> = loadManifest().then(result => {
      if (result.ok) {
        if (manifestPromise === request) {
          cachedManifestEntries = result.entries
          cachedManifestFamilyLookup = buildManifestFamilyLookup(result.entries)
        }
      } else if (manifestPromise === request) {
        manifestPromise = undefined
      }
      return result
    })
    manifestPromise = request
  }
  return manifestPromise
}

async function loadFontBlob(safeFile: string): Promise<Uint8Array | undefined> {
  if (typeof fetch !== 'function') return undefined
  try {
    const credentials: RequestCredentials = staticAssetBase() ? 'omit' : 'same-origin'
    const res = await fetch(staticAssetURL(`/fonts/office/${safeFile}`), { credentials })
    if (!res.ok) return undefined
    const bytes = new Uint8Array(await res.arrayBuffer())
    return bytes.byteLength > 0 ? bytes : undefined
  } catch {
    return undefined
  }
}

function fetchFontBlob(file: string): Promise<Uint8Array | undefined> {
  syncCacheToFetch()
  const safeFile = file.replace(/^\/+/, '')
  let pending = blobCache.get(safeFile)
  if (!pending) {
    const request: Promise<Uint8Array | undefined> = loadFontBlob(safeFile).then(bytes => {
      if (!bytes && blobCache.get(safeFile) === request) blobCache.delete(safeFile)
      return bytes
    })
    blobCache.set(safeFile, request)
    pending = request
  }
  return pending
}

/**
 * Fetches and caches site-served font blobs under `/fonts/office/` that match `missingFamilies`
 * in `manifest.json` or their script-based regional CJK fallback family. Returns `complete: false`
 * when a manifest or font request fails so callers can retry later instead of marking those
 * families as resolved.
 */
export async function resolveOfficeFontBlobs(
  missingFamilies: readonly string[]
): Promise<{ blobs: Uint8Array[]; complete: boolean }> {
  if (!missingFamilies.length) return { blobs: [], complete: true }
  const manifest = await fetchManifest()
  if (!manifest.ok) return { blobs: [], complete: false }
  const entries = manifest.entries
  if (!entries.length) return { blobs: [], complete: true }
  const lookup = cachedManifestFamilyLookup ?? buildManifestFamilyLookup(entries)

  const matchedFamilies = new Set<string>()
  for (const raw of missingFamilies) {
    const normalized = normalizeFamily(raw)
    if (!normalized) continue
    const canonical = lookup.get(normalized) ?? inferUnknownNonAsciiFallback(normalized)
    if (canonical && lookup.has(canonical)) {
      matchedFamilies.add(canonical)
    }
  }

  const files = new Set<string>()
  for (const entry of entries) {
    if (matchedFamilies.has(normalizeFamily(entry.family))) {
      files.add(entry.file)
    }
  }

  const fileList = [...files]
  const loaded = await Promise.all(fileList.map(fetchFontBlob))
  const blobs = loaded.filter((bytes): bytes is Uint8Array => bytes !== undefined && bytes.byteLength > 0)
  return {
    blobs,
    complete: blobs.length === fileList.length
  }
}

export type OfficeFontCoordinator = {
  peek(
    requests: OfficeFontRequests | readonly string[],
    isLoaded?: boolean
  ): {
    epoch: number
    fontsReady: boolean
  }
  sync(
    requests: OfficeFontRequests | readonly string[],
    options?: OfficeFontOptions
  ): {
    epoch: number
    fontsReady: boolean
  }
  getState(): { epoch: number; fontsReady: boolean; allSettled: boolean }
  waitForFonts(): Promise<void>
  subscribe(listener: () => void): () => void
  dispose(): void
}

/**
 * Coordinates on-demand `/fonts/office/` resolution, Worker registration, bounded transient
 * retry, initial-open skeleton readiness, and PDF export readiness for one Office session.
 *
 * Lifecycle is restartable across `dispose()` followed by `subscribe()` / `sync()` so React
 * `<StrictMode>` effect cleanup and remount replay cleanly without stranding in-flight work.
 */
export function createOfficeFontCoordinator<TSnapshot extends OfficeSnapshotBase>(
  model: OfficeFontModel<TSnapshot>,
  initialOptions?: OfficeFontOptions
): OfficeFontCoordinator {
  let documentLoaded = initialOptions?.documentLoaded ?? false
  let initialGateTimeoutMs = initialOptions?.initialGateTimeoutMs ?? INITIAL_FONTS_GATE_TIMEOUT_MS
  let exportWaitTimeoutMs = initialOptions?.exportWaitTimeoutMs ?? EXPORT_FONTS_WAIT_TIMEOUT_MS
  let retryDelayMs = initialOptions?.retryDelayMs ?? TRANSIENT_RETRY_DELAY_MS

  let latestRequests: OfficeFontRequests | readonly string[] = []
  let hasSynced = initialOptions?.documentLoaded !== undefined
  const attempted = new Set<string>()
  const failures = new Map<string, number>()
  const inFlightFamilies = new Set<string>()
  const waiters = new Set<() => void>()
  const listeners = new Set<() => void>()

  let activeFetchCount = 0
  let manifestBootstrapping = false
  let epoch = 0
  let initialGateReleased = false
  let active = true
  let lifecycleId = 1
  let gateTimer: ReturnType<typeof setTimeout> | undefined
  let retryTimer: ReturnType<typeof setTimeout> | undefined

  const notify = () => {
    if (!active) return
    for (const listener of listeners) listener()
  }

  const recordTransientBatchFailure = (families: readonly string[]): boolean => {
    let shouldRetry = false
    for (const family of families) {
      const count = failures.get(family) ?? 0
      if (count >= MAX_TRANSIENT_RETRIES) {
        attempted.add(family)
      } else {
        failures.set(family, count + 1)
        shouldRetry = true
      }
    }
    return shouldRetry
  }

  const flushWaitersIfSettled = () => {
    const pending = selectPendingFontFamilies(latestRequests, attempted)
    if (documentLoaded && pending.length === 0 && activeFetchCount === 0 && retryTimer === undefined) {
      initialGateReleased = true
      if (gateTimer !== undefined) {
        clearTimeout(gateTimer)
        gateTimer = undefined
      }
      if (waiters.size > 0) {
        const current = [...waiters]
        waiters.clear()
        for (const resolve of current) resolve()
      }
    }
  }

  const computeState = () => {
    const pending = selectPendingFontFamilies(latestRequests, attempted)
    const allSettled = documentLoaded && pending.length === 0 && activeFetchCount === 0 && retryTimer === undefined
    if (allSettled) {
      initialGateReleased = true
      if (gateTimer !== undefined) {
        clearTimeout(gateTimer)
        gateTimer = undefined
      }
    }
    const fontsReady = documentLoaded && (initialGateReleased || pending.length === 0)
    return { epoch, fontsReady, allSettled, pending }
  }

  const ensureGateTimer = (fontsReady: boolean) => {
    if (!documentLoaded || fontsReady || !active) {
      if (gateTimer !== undefined) {
        clearTimeout(gateTimer)
        gateTimer = undefined
      }
      return
    }
    if (gateTimer === undefined) {
      const runId = lifecycleId
      gateTimer = setTimeout(() => {
        gateTimer = undefined
        if (!active || lifecycleId !== runId || initialGateReleased) return
        initialGateReleased = true
        notify()
      }, initialGateTimeoutMs)
    }
  }

  const reactivateIfDisposed = () => {
    if (!active) {
      active = true
      lifecycleId += 1
    }
  }

  const pump = () => {
    if (!active || !documentLoaded) return
    const { fontsReady, pending } = computeState()
    ensureGateTimer(fontsReady)
    const candidateBatch = pending.filter(family => !inFlightFamilies.has(family))
    if (candidateBatch.length === 0) {
      flushWaitersIfSettled()
      return
    }
    if (!cachedManifestEntries && manifestBootstrapping) {
      return
    }

    const runId = lifecycleId
    const needsManifestBootstrap = !cachedManifestEntries
    if (needsManifestBootstrap) {
      manifestBootstrapping = true
    } else {
      for (const family of candidateBatch) inFlightFamilies.add(family)
    }
    activeFetchCount += 1

    void (async () => {
      let shouldRetry = false
      let trackedBatch: string[] = needsManifestBootstrap ? [] : candidateBatch
      try {
        let entries = cachedManifestEntries
        if (!entries) {
          const manifest = await fetchManifest()
          if (!active || lifecycleId !== runId) return
          manifestBootstrapping = false
          if (!manifest.ok) {
            const failedFamilies = selectPendingFontFamilies(latestRequests, attempted).filter(
              family => !inFlightFamilies.has(family)
            )
            shouldRetry = recordTransientBatchFailure(failedFamilies)
            return
          }
          entries = manifest.entries
          trackedBatch = selectPendingFontFamilies(latestRequests, attempted, entries).filter(
            family => !inFlightFamilies.has(family)
          )
          if (trackedBatch.length === 0) return
          for (const family of trackedBatch) inFlightFamilies.add(family)
        }

        const { blobs, complete } = await resolveOfficeFontBlobs(trackedBatch)
        if (!active || lifecycleId !== runId) return

        const newlyAttempted: string[] = []
        if (complete) {
          newlyAttempted.push(...trackedBatch)
        } else {
          for (const family of trackedBatch) {
            const count = failures.get(family) ?? 0
            if (count >= MAX_TRANSIENT_RETRIES) {
              newlyAttempted.push(family)
            } else {
              failures.set(family, count + 1)
              shouldRetry = true
            }
          }
        }

        if (blobs.length > 0) {
          for (const family of newlyAttempted) attempted.add(family)
          const updated = await model.updateSelection(async engine => {
            const fontEngine = engine as OfficeSyncEngine<TSnapshot> & {
              addFonts(fontBlobs: Uint8Array[]): Promise<TSnapshot>
            }
            return { snapshot: await fontEngine.addFonts(blobs) }
          })
          if (!active || lifecycleId !== runId) {
            for (const family of newlyAttempted) attempted.delete(family)
            return
          }
          if (!updated) {
            for (const family of newlyAttempted) attempted.delete(family)
            return
          }
          epoch += 1
        } else if (newlyAttempted.length > 0) {
          for (const family of newlyAttempted) attempted.add(family)
        }
      } catch {
        if (active && lifecycleId === runId) {
          for (const family of trackedBatch) attempted.add(family)
        }
      } finally {
        if (active && lifecycleId === runId) {
          manifestBootstrapping = false
          for (const family of trackedBatch) inFlightFamilies.delete(family)
          activeFetchCount = Math.max(0, activeFetchCount - 1)
          if (shouldRetry && retryTimer === undefined) {
            retryTimer = setTimeout(() => {
              retryTimer = undefined
              if (active && lifecycleId === runId) pump()
            }, retryDelayMs)
          }
          const nextPending = selectPendingFontFamilies(latestRequests, attempted).filter(
            family => !inFlightFamilies.has(family)
          )
          if (!shouldRetry && nextPending.length > 0) {
            pump()
          } else {
            flushWaitersIfSettled()
          }
          notify()
        }
      }
    })()
  }

  return {
    peek(requests, isLoaded = documentLoaded) {
      const pending = selectPendingFontFamilies(requests, attempted)
      const allSettled = isLoaded && pending.length === 0 && activeFetchCount === 0 && retryTimer === undefined
      const ready = isLoaded && (initialGateReleased || allSettled || pending.length === 0)
      return { epoch, fontsReady: ready }
    },
    sync(requests, options) {
      reactivateIfDisposed()
      hasSynced = true
      latestRequests = requests
      if (options?.documentLoaded !== undefined) documentLoaded = options.documentLoaded
      if (options?.initialGateTimeoutMs !== undefined) initialGateTimeoutMs = options.initialGateTimeoutMs
      if (options?.exportWaitTimeoutMs !== undefined) exportWaitTimeoutMs = options.exportWaitTimeoutMs
      if (options?.retryDelayMs !== undefined) retryDelayMs = options.retryDelayMs
      const { fontsReady } = computeState()
      ensureGateTimer(fontsReady)
      pump()
      const next = computeState()
      return { epoch: next.epoch, fontsReady: next.fontsReady }
    },
    getState() {
      const { epoch: currentEpoch, fontsReady, allSettled } = computeState()
      return { epoch: currentEpoch, fontsReady, allSettled }
    },
    waitForFonts() {
      reactivateIfDisposed()
      pump()
      if (computeState().allSettled) return Promise.resolve()
      return new Promise<void>(resolve => {
        let settled = false
        const finish = () => {
          if (settled) return
          settled = true
          clearTimeout(timer)
          waiters.delete(finish)
          resolve()
        }
        const timer = setTimeout(finish, exportWaitTimeoutMs)
        waiters.add(finish)
      })
    },
    subscribe(listener) {
      const wasInactive = !active
      reactivateIfDisposed()
      listeners.add(listener)
      if (wasInactive && hasSynced) {
        const { fontsReady } = computeState()
        ensureGateTimer(fontsReady)
        pump()
      }
      return () => {
        listeners.delete(listener)
      }
    },
    dispose() {
      active = false
      lifecycleId += 1
      manifestBootstrapping = false
      activeFetchCount = 0
      inFlightFamilies.clear()
      if (gateTimer !== undefined) {
        clearTimeout(gateTimer)
        gateTimer = undefined
      }
      if (retryTimer !== undefined) {
        clearTimeout(retryTimer)
        retryTimer = undefined
      }
      listeners.clear()
      const currentWaiters = [...waiters]
      waiters.clear()
      for (const resolve of currentWaiters) resolve()
    }
  }
}

export function useOfficeFonts<TSnapshot extends OfficeSnapshotBase>(
  requests: OfficeFontRequests | readonly string[],
  model: OfficeFontModel<TSnapshot>,
  options?: OfficeFontOptions
): OfficeFontStatus {
  const coordinator = useMemo(() => createOfficeFontCoordinator(model), [model])
  const [, setTick] = useState(0)

  useEffect(() => {
    const unsubscribe = coordinator.subscribe(() => {
      setTick(value => value + 1)
    })
    return () => {
      unsubscribe()
      coordinator.dispose()
    }
  }, [coordinator])

  const documentLoaded = options?.documentLoaded ?? true
  const initialGateTimeoutMs = options?.initialGateTimeoutMs
  const exportWaitTimeoutMs = options?.exportWaitTimeoutMs
  const retryDelayMs = options?.retryDelayMs

  useEffect(() => {
    coordinator.sync(requests, {
      documentLoaded,
      initialGateTimeoutMs,
      exportWaitTimeoutMs,
      retryDelayMs
    })
  }, [coordinator, requests, documentLoaded, initialGateTimeoutMs, exportWaitTimeoutMs, retryDelayMs])

  const { epoch, fontsReady } = coordinator.peek(requests, documentLoaded)

  return {
    epoch,
    fontsReady,
    waitForFonts: coordinator.waitForFonts
  }
}
