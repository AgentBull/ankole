import type { FileRoot } from './roots'

export type { FileRoot } from './roots'

export type FileAddress = {
  root: FileRoot
  relativePath: string
  virtualPath: string
}

export type FingerprintCacheEntry = {
  size: number
  mtimeMs: number
  xxh3_128: string
}

export type FileLaneState = {
  fingerprints: Map<string, FingerprintCacheEntry>
}

export type ListEntry = {
  relative_path: string
  kind: 'file' | 'directory' | 'other'
  size: number
  modified_unix_ms: number
}
