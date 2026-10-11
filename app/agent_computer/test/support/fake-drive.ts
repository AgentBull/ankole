import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { Drive } from '../../src/drive/drive'
import { type RPCRequester } from '../../src/lanes/rpc_lane'

/** One file in the fake drive. */
export type FakeDriveFile = { content: Buffer; sha256: string; contentType: string; source: string; mode: number }

type WireFile = {
  path: string
  sha256: string
  size: bigint
  contentType: string
  source: string
  mode: number
  updatedAt: string
}

/**
 * In-memory stand-in for the control plane's side of the `files.*` RPCs.
 *
 * `files.get` writes real bytes into the Agent Home and `files.commit` reads
 * them from there, as the WorkerFiles relay does, so tests exercise the real
 * `Drive` client and the local files it names.
 */
export class FakeDrive {
  readonly files = new Map<string, FakeDriveFile>()
  readonly calls: Array<{ method: string; payload: Record<string, unknown> }> = []

  constructor(readonly agentHome: string) {}

  /** A `Drive` client whose RPCs this fake answers. */
  drive(): Drive {
    return new Drive({ agentHome: this.agentHome, rpc: this.rpc })
  }

  /** Puts one file into the drive without a Worker transfer. */
  put(path: string, content: string | Buffer, opts: { source?: string; mode?: number; contentType?: string } = {}) {
    const bytes = Buffer.isBuffer(content) ? content : Buffer.from(content)
    this.files.set(path, {
      content: bytes,
      sha256: sha256(bytes),
      contentType: opts.contentType ?? 'application/octet-stream',
      source: opts.source ?? 'agent',
      mode: opts.mode ?? 0o644
    })
  }

  /** Returns the text of one drive file, or undefined. */
  text(path: string): string | undefined {
    return this.files.get(path)?.content.toString('utf8')
  }

  /** Lists drive paths under a folder prefix, in path order. */
  paths(prefix = ''): string[] {
    return [...this.files.keys()].filter(path => underPrefix(path, prefix)).sort()
  }

  readonly rpc: RPCRequester = (async (method: string, payload: Record<string, unknown>) => {
    this.calls.push({ method, payload })
    if (method === 'files.list') return this.list(payload)
    if (method === 'files.get') return this.get(payload)
    if (method === 'files.commit') return this.commit(payload)
    throw new Error(`fake drive does not answer ${method}`)
  }) as unknown as RPCRequester

  private list(payload: Record<string, unknown>) {
    const prefix = String(payload.prefix ?? '')
    const after = String(payload.after ?? '')
    const limit = Number(payload.limit ?? 1000)
    const matching = this.paths(prefix).filter(path => after === '' || path > after)
    const page = matching.slice(0, limit)
    return {
      files: page.map(path => this.wire(path)),
      nextAfter: matching.length > limit ? page[page.length - 1]! : '',
      revision: sha256(
        Buffer.from(
          JSON.stringify(
            this.paths(prefix).map(path => {
              const file = this.files.get(path)!
              return [path, file.sha256, file.mode]
            })
          )
        )
      )
    }
  }

  private get(payload: Record<string, unknown>) {
    const path = String(payload.path)
    const file = this.files.get(path)
    if (!file) throw new Error(`file not found: ${path}`)
    const target = join(this.agentHome, String(payload.homeRelativePath))
    mkdirSync(dirname(target), { recursive: true })
    writeFileSync(target, file.content)
    return { file: this.wire(path) }
  }

  private commit(payload: Record<string, unknown>) {
    const deletes = (payload.deletes as string[] | undefined) ?? []
    let deleted = 0
    for (const prefix of deletes) {
      for (const path of this.paths(prefix)) {
        this.files.delete(path)
        deleted += 1
      }
    }

    const upserts = (payload.upserts as Array<Record<string, unknown>> | undefined) ?? []
    const committed = upserts.map(upsert => {
      const path = String(upsert.path)
      const homeRelativePath = String(upsert.homeRelativePath ?? '')
      const declared = String(upsert.sha256 ?? '')
      const known = declared ? [...this.files.values()].find(file => file.sha256 === declared) : undefined
      const content = known && homeRelativePath === '' ? known.content : this.readLocal(homeRelativePath, path)
      if (declared && sha256(content) !== declared) throw new Error(`sha256 mismatch for ${path}`)
      this.files.set(path, {
        content,
        sha256: sha256(content),
        contentType: String(upsert.contentType || known?.contentType || 'application/octet-stream'),
        source: path.startsWith('sent/') ? 'sent' : 'agent',
        mode: Number(upsert.mode || 0o644)
      })
      return this.wire(path)
    })
    return { files: committed, deleted }
  }

  private readLocal(homeRelativePath: string, path: string): Buffer {
    if (homeRelativePath === '') throw new Error(`blob missing for ${path}`)
    return readFileSync(join(this.agentHome, homeRelativePath))
  }

  private wire(path: string): WireFile {
    const file = this.files.get(path)!
    return {
      path,
      sha256: file.sha256,
      size: BigInt(file.content.byteLength),
      contentType: file.contentType,
      source: file.source,
      mode: file.mode,
      updatedAt: '2026-10-02T00:00:00Z'
    }
  }
}

function sha256(content: Buffer): string {
  return new Bun.CryptoHasher('sha256').update(content).digest('hex')
}

function underPrefix(path: string, prefix: string): boolean {
  return prefix === '' || path === prefix || path.startsWith(`${prefix}/`)
}
