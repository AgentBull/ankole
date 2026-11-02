import { request } from 'node:http'
import { chmod, chown, mkdir } from 'node:fs/promises'
import { join } from 'node:path'
import type { DriveVfsConfig } from '../fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import { isRootWorker } from '../common/agent-user'
import { scopedPath, visibleDrivePath } from './paths'

const root = '/run/ankole-drives'
const cache = '/var/cache/ankole/rclone'
const socket = '/run/ankole/rclone.sock'
type WriteResult = { Path: string; NodeID: string; Failure: string; Recovery: string }
type Mount = {
  key: string
  path: string
  references: number
  idle?: ReturnType<typeof setTimeout>
  token: string
  endpoint: string
  refresh?: ReturnType<typeof setInterval>
  retiring?: Promise<void>
}

function rc<T>(method: string, body: Record<string, unknown>, signal = AbortSignal.timeout(15_000)): Promise<T> {
  return new Promise((resolve, reject) => {
    const req = request(
      {
        socketPath: socket,
        path: `/${method}`,
        method: 'POST',
        signal,
        headers: { 'content-type': 'application/json' }
      },
      response => {
        const chunks: Buffer[] = []
        response.on('data', chunk => chunks.push(chunk))
        response.on('error', reject)
        response.on('end', () => {
          try {
            const result = JSON.parse(Buffer.concat(chunks).toString())
            if (response.statusCode !== 200) {
              reject(new Error(result.error || `rclone ${method}: HTTP ${response.statusCode}`))
            } else resolve(result as T)
          } catch (error) {
            reject(error)
          }
        })
      }
    )
    req.on('error', reject)
    req.end(JSON.stringify(body))
  })
}

export class DriveView {
  private released = false
  constructor(
    readonly key: string,
    readonly scope: Mount,
    readonly chat: Mount | undefined,
    readonly recovery: string,
    private readonly releaseMount: (mount: Mount) => Promise<void>,
    private readonly releasedView: () => void
  ) {}

  /** Runs before setpriv: the supervisor remains outside the mounted view. */
  launcher(argv: string[]): string[] {
    return [
      '/usr/bin/unshare',
      '--mount',
      '--pid',
      '--fork',
      '--mount-proc',
      '--kill-child=SIGKILL',
      '--propagation',
      'private',
      '/usr/local/libexec/ankole-drive-view',
      this.scope.path,
      this.chat?.path ?? '-',
      this.recovery,
      ...argv
    ]
  }
  async sequence(): Promise<Map<string, number>> {
    return new Map(
      await Promise.all(
        this.mounts().map(async mount => {
          const result = await rc<{ sequence: number }>('ankole/sequence', { fs: mount.key })
          return [mount.key, result.sequence] as const
        })
      )
    )
  }
  async flush(since: Map<string, number>, signal = AbortSignal.timeout(120_000)): Promise<string> {
    const results = await Promise.all(
      this.mounts().map(mount =>
        rc<{ files?: WriteResult[]; background?: boolean }>(
          'ankole/flush',
          { fs: mount.key, since_seq: since.get(mount.key) ?? 0 },
          signal
        )
      )
    )
    return results
      .flatMap(result =>
        result.background
          ? ['Drive: large batch continues uploading in the background.']
          : (result.files ?? [])
              .filter(file => file.Failure)
              .map(file => `Drive write failed: ${file.Path}: ${file.Failure}; saved at ${file.Recovery}`)
      )
      .join('\n')
  }
  async flushPath(path: string, signal = AbortSignal.timeout(120_000)): Promise<string> {
    const chat = path.startsWith('/drive/ChatDrive/')
    const mount = chat ? this.chat : this.scope
    if (!mount) throw new Error('This execution has no ChatDrive')
    const remote = path.slice(chat ? '/drive/ChatDrive/'.length : '/drive/'.length)
    const result = await rc<{ files: WriteResult[] }>('ankole/flush-paths', { fs: mount.key, paths: [remote] }, signal)
    const file = result.files.find(item => item.Path === remote)
    if (file?.Failure) throw new Error(`${file.Failure}; saved at ${file.Recovery}`)
    if (file?.NodeID) return file.NodeID
    // A clean file has no pending upload. Its authoritative ID comes from DAV,
    // through the root-held remote, rather than from a guessed path identifier.
    const listing = await rc<{ item: { ID?: string } | null }>('operations/stat', { fs: `${mount.key}:`, remote })
    if (!listing.item?.ID) throw new Error(`Drive file is unavailable: ${path}`)
    return listing.item.ID
  }
  async release(): Promise<void> {
    if (this.released) return
    this.released = true
    this.releasedView()
    await Promise.all(this.mounts().map(this.releaseMount))
  }
  private mounts(): Mount[] {
    return this.chat ? [this.scope, this.chat] : [this.scope]
  }
}

/** One rcd and one cache pool per Worker; views lease the existing mounts. */
class DriveMounts {
  private starting?: Promise<void>
  private readonly mounts = new Map<string, Promise<Mount>>()
  private readonly views = new Map<string, { view: DriveView; count: number }>()
  private daemon?: ReturnType<typeof Bun.spawn>
  private stopping = false

  async resume(): Promise<void> {
    await Promise.all([...this.mounts.values()].map(async pending => this.refresh(await pending)))
    await this.invalidate()
  }

  async drain(): Promise<void> {
    for (;;) {
      const pending = await Promise.all(
        [...this.mounts.values()].map(async mount => rc<{ count: number }>('ankole/pending', { fs: (await mount).key }))
      )
      if (pending.every(result => result.count === 0)) return
      await Bun.sleep(200)
    }
  }

  async stop(): Promise<void> {
    this.stopping = true
    for (const pending of this.mounts.values()) {
      const mount = await pending.catch(() => undefined)
      if (mount) {
        clearTimeout(mount.idle)
        clearInterval(mount.refresh)
      }
    }
    this.daemon?.kill()
    await this.daemon?.exited
  }

  async acquire(config: DriveVfsConfig | undefined): Promise<DriveView | undefined> {
    if (!config) return undefined
    if (!isRootWorker()) throw new Error('Drive FUSE requires the Linux Worker supervisor')
    await (this.starting ??= this.start())
    const recovery = join(cache, 'recovery', `scope_${config.scope}`)
    await mkdir(recovery, { recursive: true, mode: 0o750 })
    await chown(recovery, 0, 1000)
    const scope = await this.mount(`scope_${config.scope}`, config.endpoint, config.token, recovery)
    try {
      const chat = config.conversationId
        ? await this.mount(
            `chat_${config.view}`,
            `${config.endpoint.replace(/\/$/, '')}/ChatDrive`,
            config.token,
            recovery
          )
        : undefined
      const view = new DriveView(
        config.view,
        scope,
        chat,
        recovery,
        mount => this.release(mount),
        () => {
          const entry = this.views.get(config.view)
          if (entry && --entry.count === 0) this.views.delete(config.view)
        }
      )
      this.views.set(config.view, { view, count: (this.views.get(config.view)?.count ?? 0) + 1 })
      return view
    } catch (error) {
      await this.release(scope)
      throw error
    }
  }

  async flushPaths(viewKey: string, paths: string[], agentHome: string, signal: AbortSignal): Promise<string[]> {
    const view = this.views.get(viewKey)?.view
    if (!view) throw new Error('The execution Drive view is not mounted')
    return Promise.all(
      paths.map(async path => {
        const target = visibleDrivePath(view, await scopedPath(view, agentHome, path, signal))
        if (!target.startsWith('/drive/')) throw new Error(`Attachment must be in Drive: ${path}`)
        return view.flushPath(target, signal)
      })
    )
  }

  async invalidate(nodeIDs: string[] = []): Promise<void> {
    await Promise.all(
      [...this.mounts.values()].map(async pending => {
        const mount = await pending
        await rc(nodeIDs.length ? 'ankole/invalidate' : 'ankole/invalidate-all-clean', {
          fs: mount.key,
          paths: nodeIDs.map(id => `id:${id}`)
        })
      })
    )
  }

  private async start(): Promise<void> {
    for (const path of [root, cache, '/run/ankole']) {
      await mkdir(path, { recursive: true, mode: 0o700 })
      await chmod(path, 0o700)
    }
    for (const path of ['/drive', '/drive-recovery']) await mkdir(path, { recursive: true, mode: 0o755 })
    const daemon = Bun.spawn(
      [
        'ankole-rclone',
        'rcd',
        '--config',
        '/dev/null',
        '--rc-addr',
        socket,
        '--rc-no-auth',
        '--cache-dir',
        cache,
        '--transfers',
        '4',
        '--low-level-retries',
        '1'
      ],
      {
        stdin: 'ignore',
        stdout: 'ignore',
        stderr: 'inherit',
        env: { PATH: process.env.PATH!, ANKOLE_WORKER_CACHE_CAPACITY: process.env.ANKOLE_WORKER_CACHE_CAPACITY }
      }
    )
    this.daemon = daemon
    void daemon.exited.then(() => {
      if (!this.stopping) process.kill(process.pid, 'SIGTERM')
    })
    const deadline = Date.now() + 15_000
    for (;;) {
      try {
        await rc('core/version', {})
        await chmod(socket, 0o600)
        return
      } catch (error) {
        if (daemon.exitCode !== null || Date.now() >= deadline) {
          daemon.kill()
          throw error
        }
        await Bun.sleep(50)
      }
    }
  }

  private async mount(key: string, url: string, token: string, recovery: string): Promise<Mount> {
    let pending = this.mounts.get(key)
    if (!pending) {
      pending = (async () => {
        const path = join(root, key)
        await mkdir(path, { recursive: true, mode: 0o700 })
        await rc('config/create', {
          name: key,
          type: 'webdav',
          parameters: {
            url,
            vendor: 'ankole',
            bearer_token: token,
            ...(key.startsWith('scope_') ? { headers: 'X-Ankole-Shared-Scope,1' } : {})
          }
        })
        await rc('mount/mount', {
          fs: `${key}:`,
          mountPoint: path,
          mountType: 'mount2',
          mountOpt: { AllowOther: true, AttrTimeout: 1_000_000_000 },
          vfsOpt: {
            CacheMode: 3,
            WriteBack: 1_000_000_000,
            CacheMaxAge: 86_400_000_000_000,
            DirCacheTime: 300_000_000_000,
            PollInterval: 0,
            Links: true,
            UID: 1000,
            GID: 1000,
            FilePerms: 511,
            DirPerms: 511
          }
        })
        const mount: Mount = { key, path, references: 0, token, endpoint: url }
        mount.refresh = setInterval(
          () => void this.refresh(mount).catch(error => console.error('Drive token refresh failed:', error)),
          20 * 60_000
        )
        mount.refresh.unref()
        return mount
      })()
      this.mounts.set(key, pending)
      void pending.catch(() => {
        if (this.mounts.get(key) === pending) this.mounts.delete(key)
      })
    }
    const mount = await pending
    if (mount.retiring) {
      await mount.retiring
      return this.mount(key, url, token, recovery)
    }
    mount.token = token
    if (mount.idle) clearTimeout(mount.idle)
    mount.references++
    try {
      await rc('ankole/configure', { fs: key, token, recovery })
      return mount
    } catch (error) {
      await this.release(mount)
      throw error
    }
  }

  private async refresh(mount: Mount): Promise<void> {
    const endpoint = new URL('/api/v1/vfs/refresh', mount.endpoint)
    const response = await fetch(endpoint, {
      method: 'POST',
      headers: { authorization: `Bearer ${mount.token}` },
      signal: AbortSignal.timeout(15_000)
    })
    if (!response.ok) throw new Error(`Drive credential refresh: HTTP ${response.status}`)
    const { token } = (await response.json()) as { token: string }
    await rc('ankole/configure', {
      fs: mount.key,
      token,
      upload_limit: Number(response.headers.get('x-ankole-upload-limit'))
    })
    mount.token = token
  }

  private async release(mount: Mount): Promise<void> {
    mount.references--
    if (mount.references !== 0) return
    const expire = async () => {
      if (mount.references !== 0) return
      try {
        const pending = await rc<{ count: number }>('ankole/pending', { fs: mount.key })
        if (mount.references !== 0) return
        if (pending.count) {
          mount.idle = setTimeout(() => void expire(), 60_000)
          mount.idle.unref()
          return
        }
        mount.retiring = rc('mount/unmount', { mountPoint: mount.path })
          .then(() => {
            clearInterval(mount.refresh)
            this.mounts.delete(mount.key)
          })
          .finally(() => {
            mount.retiring = undefined
          })
        await mount.retiring
      } catch {
        mount.idle = setTimeout(() => void expire(), 60_000)
        mount.idle.unref()
      }
    }
    mount.idle = setTimeout(() => void expire(), 15 * 60_000)
    mount.idle.unref()
  }
}

export const driveMounts = new DriveMounts()
