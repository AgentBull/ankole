import { xxh3File128Hex } from '@ankole/kernel'
import { statSync } from 'node:fs'
import { normalizeRelativePath } from './path-security'
import type { FileRoot, FileTransferState } from './types'

export async function fileFingerprint(
  state: FileTransferState,
  root: FileRoot,
  relativePath: string,
  filePath: string
): Promise<string> {
  const stat = statSync(filePath)
  const key = fingerprintCacheKey(root, relativePath)
  const cached = state.fingerprints.get(key)
  if (cached && cached.size === stat.size && cached.mtimeMs === stat.mtimeMs) {
    return cached.xxh3_128
  }

  const xxh3_128 = await xxh3File128Hex(filePath)
  state.fingerprints.set(key, { size: stat.size, mtimeMs: stat.mtimeMs, xxh3_128 })
  return xxh3_128
}

export function forgetFingerprint(state: FileTransferState, root: FileRoot, relativePath: string): void {
  state.fingerprints.delete(fingerprintCacheKey(root, normalizeRelativePath(relativePath)))
}

export function forgetFingerprintTree(state: FileTransferState, root: FileRoot, relativePath: string): void {
  const prefix = `${root}:${normalizeRelativePath(relativePath)}`
  for (const key of state.fingerprints.keys()) {
    if (key === prefix || key.startsWith(`${prefix}/`)) {
      state.fingerprints.delete(key)
    }
  }
}

function fingerprintCacheKey(root: FileRoot, relativePath: string): string {
  return `${root}:${normalizeRelativePath(relativePath)}`
}
