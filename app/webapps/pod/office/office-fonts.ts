import { useEffect, useRef, useState } from 'react'
import type { OfficeSnapshotBase, OfficeSyncEngine } from './office-collaboration'

export type OfficeFontManifestEntry = {
  family: string
  aliases?: string[]
  file: string
}

type OfficeFontManifest = {
  fonts?: OfficeFontManifestEntry[]
}

type ManifestLookup = {
  ok: boolean
  entries: OfficeFontManifestEntry[]
}

const CJK_FAMILY_FALLBACKS: Record<string, string> = {
  // Simplified Chinese — Sans
  'noto sans sc': 'noto sans sc',
  'noto sans cjk sc': 'noto sans sc',
  'source han sans sc': 'noto sans sc',
  'source han sans cn': 'noto sans sc',
  'microsoft yahei': 'noto sans sc',
  'microsoft yahei ui': 'noto sans sc',
  微软雅黑: 'noto sans sc',
  dengxian: 'noto sans sc',
  等线: 'noto sans sc',
  simhei: 'noto sans sc',
  黑体: 'noto sans sc',
  'pingfang sc': 'noto sans sc',
  '苹方-简': 'noto sans sc',
  'heiti sc': 'noto sans sc',
  stheitisc: 'noto sans sc',
  华文黑体: 'noto sans sc',
  // Simplified Chinese — Serif
  'noto serif sc': 'noto serif sc',
  'noto serif cjk sc': 'noto serif sc',
  'source han serif sc': 'noto serif sc',
  'source han serif cn': 'noto serif sc',
  simsun: 'noto serif sc',
  宋体: 'noto serif sc',
  nsimsun: 'noto serif sc',
  新宋体: 'noto serif sc',
  'songti sc': 'noto serif sc',
  fangsong: 'noto serif sc',
  仿宋: 'noto serif sc',
  kaiti: 'noto serif sc',
  楷体: 'noto serif sc',
  // Traditional Chinese — Sans
  'noto sans tc': 'noto sans tc',
  'noto sans cjk tc': 'noto sans tc',
  'source han sans tc': 'noto sans tc',
  'source han sans tw': 'noto sans tc',
  'source han sans hk': 'noto sans tc',
  'microsoft jhenghei': 'noto sans tc',
  'microsoft jhenghei ui': 'noto sans tc',
  微軟正黑體: 'noto sans tc',
  'pingfang tc': 'noto sans tc',
  'pingfang hk': 'noto sans tc',
  '苹方-繁': 'noto sans tc',
  'heiti tc': 'noto sans tc',
  // Traditional Chinese — Serif
  'noto serif tc': 'noto serif tc',
  'noto serif cjk tc': 'noto serif tc',
  'source han serif tc': 'noto serif tc',
  'source han serif tw': 'noto serif tc',
  pmingliu: 'noto serif tc',
  新細明體: 'noto serif tc',
  mingliu: 'noto serif tc',
  細明體: 'noto serif tc',
  'dfkai-sb': 'noto serif tc',
  標楷體: 'noto serif tc',
  // Japanese — Sans
  'noto sans jp': 'noto sans jp',
  'noto sans cjk jp': 'noto sans jp',
  'source han sans jp': 'noto sans jp',
  'source han sans': 'noto sans jp',
  'yu gothic': 'noto sans jp',
  'yu gothic ui': 'noto sans jp',
  游ゴシック: 'noto sans jp',
  meiryo: 'noto sans jp',
  'meiryo ui': 'noto sans jp',
  メイリオ: 'noto sans jp',
  'ms pgothic': 'noto sans jp',
  'ｍｓ ｐゴシック': 'noto sans jp',
  'ms gothic': 'noto sans jp',
  'ｍｓ ゴシック': 'noto sans jp',
  'hiragino kaku gothic pron': 'noto sans jp',
  'hiragino sans': 'noto sans jp',
  'ヒラギノ角ゴ pron': 'noto sans jp',
  // Japanese — Serif
  'noto serif jp': 'noto serif jp',
  'noto serif cjk jp': 'noto serif jp',
  'source han serif jp': 'noto serif jp',
  'ms mincho': 'noto serif jp',
  'ｍｓ 明朝': 'noto serif jp',
  'ms pmincho': 'noto serif jp',
  'ｍｓ ｐ明朝': 'noto serif jp',
  'yu mincho': 'noto serif jp',
  游明朝: 'noto serif jp',
  'hiragino mincho pron': 'noto serif jp',
  // Korean — Sans
  'noto sans kr': 'noto sans kr',
  'noto sans cjk kr': 'noto sans kr',
  'source han sans kr': 'noto sans kr',
  'source han sans k': 'noto sans kr',
  'malgun gothic': 'noto sans kr',
  '맑은 고딕': 'noto sans kr',
  'apple sd gothic neo': 'noto sans kr',
  dotum: 'noto sans kr',
  돋움: 'noto sans kr',
  gulim: 'noto sans kr',
  굴림: 'noto sans kr',
  // Korean — Serif
  'noto serif kr': 'noto serif kr',
  'noto serif cjk kr': 'noto serif kr',
  'source han serif kr': 'noto serif kr',
  batang: 'noto serif kr',
  바탕: 'noto serif kr',
  gungsuh: 'noto serif kr',
  궁서: 'noto serif kr'
}

const HANGUL_RE = /[\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]/
const KANA_RE = /[\u3040-\u30ff\uff66-\uff9f]/

let cachedFetch: typeof fetch | undefined
let manifestPromise: Promise<ManifestLookup> | undefined
const blobCache = new Map<string, Promise<Uint8Array | undefined>>()

function syncCacheToFetch(): void {
  const currentFetch = typeof fetch === 'function' ? fetch : undefined
  if (cachedFetch !== currentFetch) {
    cachedFetch = currentFetch
    manifestPromise = undefined
    blobCache.clear()
  }
}

function normalizeFamily(name: string): string {
  return name.trim().toLowerCase()
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
  return 'noto sans sc'
}

async function loadManifest(): Promise<ManifestLookup> {
  if (typeof fetch !== 'function') return { ok: true, entries: [] }
  try {
    const res = await fetch('/fonts/office/manifest.json', { credentials: 'same-origin' })
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
      if (!result.ok && manifestPromise === request) manifestPromise = undefined
      return result
    })
    manifestPromise = request
  }
  return manifestPromise
}

async function loadFontBlob(safeFile: string): Promise<Uint8Array | undefined> {
  if (typeof fetch !== 'function') return undefined
  try {
    const res = await fetch(`/fonts/office/${safeFile}`, { credentials: 'same-origin' })
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
 * or their selective regional CJK fallback family. Returns `complete: false` when a manifest or
 * font request fails so callers can retry later instead of marking those families as resolved.
 */
export async function resolveOfficeFontBlobs(
  missingFamilies: readonly string[]
): Promise<{ blobs: Uint8Array[]; complete: boolean }> {
  if (!missingFamilies.length) return { blobs: [], complete: true }
  const manifest = await fetchManifest()
  if (!manifest.ok) return { blobs: [], complete: false }
  if (!manifest.entries.length) return { blobs: [], complete: true }

  const knownManifestNames = new Set<string>()
  for (const entry of manifest.entries) {
    knownManifestNames.add(normalizeFamily(entry.family))
    for (const alias of entry.aliases ?? []) {
      knownManifestNames.add(normalizeFamily(alias))
    }
  }

  const wanted = new Set<string>()
  for (const raw of missingFamilies) {
    const normalized = normalizeFamily(raw)
    if (!normalized) continue
    wanted.add(normalized)
    const cjkTarget = CJK_FAMILY_FALLBACKS[normalized]
    if (cjkTarget) {
      wanted.add(cjkTarget)
      continue
    }
    if (!knownManifestNames.has(normalized)) {
      const scriptFallback = inferUnknownNonAsciiFallback(normalized)
      if (scriptFallback) wanted.add(scriptFallback)
    }
  }

  const matchedFamilies = new Set<string>()
  for (const entry of manifest.entries) {
    const familyName = normalizeFamily(entry.family)
    const names = [familyName, ...(entry.aliases ?? []).map(normalizeFamily)]
    if (names.some(name => wanted.has(name))) {
      matchedFamilies.add(familyName)
    }
  }

  const files = new Set<string>()
  for (const entry of manifest.entries) {
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

export function useOfficeFonts<TSnapshot extends OfficeSnapshotBase>(
  families: readonly string[],
  model: {
    updateSelection: (
      task: (engine: OfficeSyncEngine<TSnapshot>) => Promise<{ snapshot: TSnapshot }>
    ) => Promise<TSnapshot | undefined>
  }
): number {
  const attempted = useRef(new Set<string>())
  const [epoch, setEpoch] = useState(0)
  const familiesKey = [...new Set(families.map(normalizeFamily).filter(Boolean))].sort().join('\0')

  useEffect(() => {
    if (!familiesKey) return
    const missing = familiesKey.split('\0').filter(family => !attempted.current.has(family))
    if (missing.length === 0) return
    let cancelled = false
    void resolveOfficeFontBlobs(missing)
      .then(async ({ blobs, complete }) => {
        if (cancelled) return
        if (blobs.length > 0) {
          const updated = await model.updateSelection(async engine => {
            const fontEngine = engine as OfficeSyncEngine<TSnapshot> & {
              addFonts(blobs: Uint8Array[]): Promise<TSnapshot>
            }
            return { snapshot: await fontEngine.addFonts(blobs) }
          })
          if (!updated) return
          setEpoch(value => value + 1)
        }
        if (complete) {
          for (const family of missing) attempted.current.add(family)
        }
      })
      .catch(() => undefined)
    return () => {
      cancelled = true
    }
  }, [familiesKey, model])

  return epoch
}
