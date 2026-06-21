import { FileWriter } from './api-client/file-writer'
import type { WorkerClient } from './api-client/worker-client'
import type { DirEntry, FileStat, ComputerFile } from './types'
import { readableToBuffer } from './utils/consume-readable'

const WORKSPACE_ROOT = '/workspace'

export interface ReadFileRef {
  path: string
  cwd?: string
}

export interface DownloadTarget {
  /** Local destination path (on the machine running the SDK). */
  path: string
  /** Optional local base directory the `path` is resolved against. */
  cwd?: string
}

/** File operations against a computer session. Exposed as `computer.fs`. */
export class FileSystem {
  constructor(private readonly client: WorkerClient) {}

  async mkdir(path: string, opts: { cwd?: string; signal?: AbortSignal } = {}): Promise<void> {
    await this.client.mkdir(path, opts.cwd, true, opts.signal)
  }

  /**
   * Uploads files to the computer. They are packed into one `tar.gz` and sent as a
   * single request, so a batch is one round-trip and the worker extracts them
   * atomically under `cwd`. `cwd` defaults to the workspace root.
   */
  async writeFiles(files: ComputerFile[], opts: { cwd?: string; signal?: AbortSignal } = {}): Promise<void> {
    const tarGz = await FileWriter.pack(files)
    await this.client.writeFiles(tarGz, opts.cwd ?? WORKSPACE_ROOT, opts.signal)
  }

  /**
   * Opens a file for reading as a byte stream, or returns `null` when it does not
   * exist (the worker answers 404). Streaming avoids buffering large files in
   * memory; callers that want the whole content use {@link readFileToBuffer}.
   */
  async readFile(file: ReadFileRef, opts: { signal?: AbortSignal } = {}): Promise<ReadableStream<Uint8Array> | null> {
    const response = await this.client.readFile(file.path, file.cwd, opts.signal)
    return response ? response.body : null
  }

  async readFileToBuffer(file: ReadFileRef, opts: { signal?: AbortSignal } = {}): Promise<Buffer | null> {
    const stream = await this.readFile(file, opts)
    return stream ? readableToBuffer(stream) : null
  }

  stat(file: ReadFileRef, opts: { signal?: AbortSignal } = {}): Promise<FileStat> {
    return this.client.stat(file.path, file.cwd, opts.signal)
  }

  readdir(dir: ReadFileRef, opts: { signal?: AbortSignal } = {}): Promise<DirEntry[]> {
    return this.client.readdir(dir.path, dir.cwd, opts.signal)
  }

  /** Stream a computer file to a local path. Returns the written path, or `null` if missing. */
  async downloadFile(
    src: ReadFileRef,
    dst: DownloadTarget,
    opts: { mkdirRecursive?: boolean; signal?: AbortSignal } = {}
  ): Promise<string | null> {
    const buffer = await this.readFileToBuffer(src, { signal: opts.signal })
    if (!buffer) return null
    // Join the local base dir and path with exactly one slash: strip any trailing
    // slashes from cwd so e.g. `cwd: '/out/'` + `path: 'a.txt'` does not become
    // `/out//a.txt`. `createPath` makes missing parent dirs by default.
    const target = dst.cwd ? `${dst.cwd.replace(/\/+$/, '')}/${dst.path}` : dst.path
    await Bun.write(target, buffer, { createPath: opts.mkdirRecursive ?? true })
    return target
  }
}
