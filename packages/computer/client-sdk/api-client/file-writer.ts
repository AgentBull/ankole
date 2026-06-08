import type { ComputerFile } from '../types'
import { normalizeComputerPath } from '../utils/normalize-path'
import { createTarGz, type TarEntry } from '../utils/tar'

async function toBytes(content: ComputerFile['content']): Promise<Uint8Array> {
  if (typeof content === 'string') return new TextEncoder().encode(content)
  if (content instanceof Blob) return new Uint8Array(await content.arrayBuffer())
  // Buffer is a Uint8Array subclass, so this covers both.
  if (content instanceof Uint8Array) return content
  throw new Error('unsupported ComputerFile content (expected string | Uint8Array | Buffer | Blob)')
}

/**
 * Packs a set of files into a single `tar.gz`, mirroring the Vercel SDK's
 * `FileWriter`: each file becomes a tar entry, the archive is gzipped, and the
 * worker unpacks it under the request's `X-Cwd`.
 */
export class FileWriter {
  static async pack(files: ComputerFile[]): Promise<Uint8Array> {
    if (files.length === 0) throw new Error('writeFiles requires at least one file')
    const entries: TarEntry[] = []
    for (const file of files) {
      entries.push({
        name: normalizeComputerPath(file.path),
        data: await toBytes(file.content),
        mode: file.mode ?? 0o644
      })
    }
    return createTarGz(entries)
  }
}
