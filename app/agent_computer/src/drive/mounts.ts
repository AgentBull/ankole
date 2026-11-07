import { request } from 'node:http'
import { chmod, chown, mkdir, readFile, realpath as fsRealpath, rm, stat } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import type { DriveVfsConfig } from '../fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import { isRootWorker } from '../common/agent-user'
import { scopedPath, visibleDrivePath } from './paths'

const defaultRoot = '/run/ankole-drives'
const defaultCache = '/var/cache/ankole/rclone'
const defaultSocket = '/run/ankole/rclone.sock'
const defaultMountTimeoutMs = 60_000
const defaultIdleTimeoutMs = 15 * 60_000
const defaultRetryIdleTimeoutMs = 60_000

type WriteResult = { Path: string; NodeID: string; Failure: string; Recovery: string }
type RcCall = <T>(method: string, body: Record<string, unknown>, signal?: AbortSignal) => Promise<T>
type Mount = {
  key: string
  path: string
  references: number
  token: string
  endpoint: string
  refresh?: ReturnType<typeof setInterval>
}

export type DriveMountsOptions = {
  root?: string
  cache?: string
  socket?: string
  mountTimeoutMs?: number
  idleTimeoutMs?: number
  orphanIdleTimeoutMs?: number
  retryIdleTimeoutMs?: number
  mountInfoPath?: string
  isRoot?: () => boolean
  realpath?: (path: string) => Promise<string>
  lazyUnmount?: (mountPoint: string) => Promise<void>
  spawnDaemon?: (socketPath: string, cacheDir: string) => ReturnType<typeof Bun.spawn>
  onUnexpectedDaemonExit?: () => void
  configureSystemDirs?: boolean
}

class MountSlot {
  live?: Mount
  uncertain = false
  idle?: ReturnType<typeof setTimeout>
  inFlight = 0
  private queue: Promise<void> = Promise.resolve()

  constructor(
    readonly key: string,
    readonly path: string
  ) {}

  run<T>(fn: () => Promise<T>): Promise<T> {
    this.inFlight++
    const next = this.queue.then(fn, fn)
    this.queue = next.then(
      () => undefined,
      () => undefined
    )
    return next.finally(() => {
      this.inFlight--
    })
  }

  clearIdle(): void {
    clearTimeout(this.idle)
    this.idle = undefined
  }

  clearAllTimers(): void {
    this.clearIdle()
    clearInterval(this.live?.refresh)
    if (this.live) this.live.refresh = undefined
  }
}

function isMountNotFoundError(error: unknown): boolean {
  return /mount not found/i.test(error instanceof Error ? error.message : String(error))
}

function rcOnSocket<T>(
  socketPath: string,
  method: string,
  body: Record<string, unknown>,
  signal = AbortSignal.timeout(15_000)
): Promise<T> {
  return new Promise((resolve, reject) => {
    const req = request(
      {
        socketPath,
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
            const raw = Buffer.concat(chunks).toString()
            const result = raw ? JSON.parse(raw) : {}
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

const defaultRc: RcCall = (method, body, signal) => rcOnSocket(defaultSocket, method, body, signal)

async function defaultLazyUnmount(mountPoint: string): Promise<void> {
  const proc = Bun.spawn(['umount', '-l', mountPoint], {
    stdin: 'ignore',
    stdout: 'ignore',
    stderr: 'ignore'
  })
  await proc.exited
}

function defaultSpawnDaemon(socketPath: string, cacheDir: string): ReturnType<typeof Bun.spawn> {
  return Bun.spawn(
    [
      'ankole-rclone',
      'rcd',
      '--config',
      '/dev/null',
      '--rc-addr',
      socketPath,
      '--rc-no-auth',
      '--cache-dir',
      cacheDir,
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
}

/**
 * Extracts mount points matching `targetPath` (and optionally descendants) from Linux
 * `/proc/self/mountinfo` in reverse mount order so stacked and child mounts detach first.
 */
export function parseMountPointsUnder(mountinfo: string, targetPath: string, includeDescendants = true): string[] {
  const normalized = targetPath.replace(/\/+$/, '') || '/'
  const childPrefix = normalized === '/' ? '/' : `${normalized}/`
  const matches: string[] = []
  for (const line of mountinfo.split('\n')) {
    if (!line) continue
    const rawMountPoint = line.split(' ')[4]
    if (!rawMountPoint) continue
    const mountPoint = rawMountPoint.replace(/\\(040|011|012|134)/g, (_, code: string) => {
      if (code === '040') return ' '
      if (code === '011') return '\t'
      if (code === '012') return '\n'
      return '\\'
    })
    if (mountPoint === normalized || (includeDescendants && mountPoint.startsWith(childPrefix))) {
      matches.push(mountPoint)
    }
  }
  return matches.reverse()
}

export class DriveView {
  private released = false
  constructor(
    readonly key: string,
    readonly scope: Mount,
    readonly chat: Mount | undefined,
    readonly library: Mount,
    readonly recovery: string,
    private readonly releaseMount: (mount: Mount) => Promise<void>,
    private readonly releasedView: () => void,
    private readonly rc: RcCall = defaultRc
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
      this.library.path,
      ...argv
    ]
  }
  async sequence(): Promise<Map<string, number>> {
    return new Map(
      await Promise.all(
        this.mounts().map(async mount => {
          const result = await this.rc<{ sequence: number }>('ankole/sequence', { fs: mount.key })
          return [mount.key, result.sequence] as const
        })
      )
    )
  }
  async flush(since: Map<string, number>, signal = AbortSignal.timeout(120_000)): Promise<string> {
    const results = await Promise.all(
      this.mounts().map(mount =>
        this.rc<{ files?: WriteResult[]; background?: boolean }>(
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
    const result = await this.rc<{ files: WriteResult[] }>(
      'ankole/flush-paths',
      { fs: mount.key, paths: [remote] },
      signal
    )
    const file = result.files.find(item => item.Path === remote)
    if (file?.Failure) throw new Error(`${file.Failure}; saved at ${file.Recovery}`)
    if (file?.NodeID) return file.NodeID
    // A clean file has no pending upload. Its authoritative ID comes from DAV,
    // through the root-held remote, rather than from a guessed path identifier.
    const listing = await this.rc<{ item: { ID?: string } | null }>('operations/stat', { fs: `${mount.key}:`, remote })
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
    return this.chat ? [this.scope, this.chat, this.library] : [this.scope, this.library]
  }
}

/** One rcd and one cache pool per Worker; views lease the existing mounts. */
export class DriveMounts {
  private starting?: Promise<void>
  private readonly slots = new Map<string, MountSlot>()
  private readonly views = new Map<string, { view: DriveView; count: number }>()
  private daemon?: ReturnType<typeof Bun.spawn>
  private stopping = false
  private readonly cfg: Required<DriveMountsOptions>
  private readonly rc: RcCall

  constructor(options: DriveMountsOptions = {}) {
    const idleTimeoutMs = options.idleTimeoutMs ?? defaultIdleTimeoutMs
    this.cfg = {
      root: options.root ?? defaultRoot,
      cache: options.cache ?? defaultCache,
      socket: options.socket ?? defaultSocket,
      mountTimeoutMs: options.mountTimeoutMs ?? defaultMountTimeoutMs,
      idleTimeoutMs,
      orphanIdleTimeoutMs: options.orphanIdleTimeoutMs ?? idleTimeoutMs,
      retryIdleTimeoutMs: options.retryIdleTimeoutMs ?? defaultRetryIdleTimeoutMs,
      mountInfoPath: options.mountInfoPath ?? '/proc/self/mountinfo',
      isRoot: options.isRoot ?? isRootWorker,
      realpath: options.realpath ?? fsRealpath,
      lazyUnmount: options.lazyUnmount ?? defaultLazyUnmount,
      spawnDaemon: options.spawnDaemon ?? defaultSpawnDaemon,
      onUnexpectedDaemonExit: options.onUnexpectedDaemonExit ?? (() => process.kill(process.pid, 'SIGTERM')),
      configureSystemDirs: options.configureSystemDirs ?? options.root === undefined
    }
    this.rc = (method, body, signal) => rcOnSocket(this.cfg.socket, method, body, signal)
  }

  async resume(): Promise<void> {
    await Promise.all(
      [...this.slots.values()].map(slot =>
        slot.run(async () => {
          if (slot.live && !slot.uncertain) await this.refresh(slot.live)
        })
      )
    )
    await this.invalidate()
  }

  async drain(): Promise<void> {
    for (;;) {
      const pending = await Promise.all(
        [...this.slots.values()].map(slot =>
          slot.run(async () =>
            slot.live && !slot.uncertain
              ? this.rc<{ count: number }>('ankole/pending', { fs: slot.live.key })
              : { count: 0 }
          )
        )
      )
      if (pending.every(result => result.count === 0)) return
      await Bun.sleep(200)
    }
  }

  async stop(gracefulTimeoutMs = 5_000, forceKillTimeoutMs = 2_000): Promise<void> {
    this.stopping = true
    for (const slot of this.slots.values()) slot.clearAllTimers()
    const daemon = this.daemon
    this.daemon = undefined
    if (daemon) {
      const deadline = Date.now() + gracefulTimeoutMs
      const unmountBudgetMs = Math.max(20, Math.min(2_500, Math.floor(gracefulTimeoutMs / 2)))
      await this.rc('mount/unmountall', {}, AbortSignal.timeout(unmountBudgetMs)).catch(() => undefined)
      daemon.kill()
      const remainingGraceMs = Math.max(20, deadline - Date.now())
      if (!(await waitForProcessExit(daemon.exited, remainingGraceMs))) {
        daemon.kill('SIGKILL')
        await waitForProcessExit(daemon.exited, forceKillTimeoutMs)
      }
      await this.unmountKernelMounts(this.cfg.root, true)
      await rm(this.cfg.socket, { force: true }).catch(() => undefined)
    }
    for (const slot of this.slots.values()) {
      slot.clearAllTimers()
      slot.live = undefined
      slot.uncertain = false
    }
    this.slots.clear()
    this.views.clear()
    this.starting = undefined
    this.stopping = false
  }

  async acquire(config: DriveVfsConfig | undefined): Promise<DriveView | undefined> {
    if (!config) return undefined
    if (!this.cfg.isRoot()) throw new Error('Drive FUSE requires the Linux Worker supervisor')
    this.starting ??= this.start().catch(error => {
      this.starting = undefined
      throw error
    })
    await this.starting
    const recovery = join(this.cfg.cache, 'recovery', `scope_${config.scope}`)
    await mkdir(recovery, { recursive: true, mode: 0o750 })
    if (this.cfg.configureSystemDirs) await chown(recovery, 0, 1000)
    const scope = await this.mount(`scope_${config.scope}`, config.endpoint, config.token, recovery)
    let chat: Mount | undefined
    try {
      chat = config.conversationId
        ? await this.mount(
            `chat_${config.view}`,
            `${config.endpoint.replace(/\/$/, '')}/ChatDrive`,
            config.token,
            recovery
          )
        : undefined
      const library = await this.mount(`library_${config.libraryScope}`, config.endpoint, config.token, recovery)
      const view = new DriveView(
        config.view,
        scope,
        chat,
        library,
        recovery,
        mount => this.release(mount),
        () => {
          const entry = this.views.get(config.view)
          if (entry && --entry.count === 0) this.views.delete(config.view)
        },
        this.rc
      )
      this.views.set(config.view, { view, count: (this.views.get(config.view)?.count ?? 0) + 1 })
      return view
    } catch (error) {
      await Promise.all([scope, ...(chat ? [chat] : [])].map(mount => this.release(mount)))
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
      [...this.slots.values()].map(slot =>
        slot.run(async () => {
          if (!slot.live || slot.uncertain) return
          await this.rc(nodeIDs.length ? 'ankole/invalidate' : 'ankole/invalidate-all-clean', {
            fs: slot.live.key,
            paths: nodeIDs.map(id => `id:${id}`)
          })
        })
      )
    )
  }

  private getOrCreateSlot(key: string): MountSlot {
    let slot = this.slots.get(key)
    if (!slot) {
      slot = new MountSlot(key, join(this.cfg.root, key))
      this.slots.set(key, slot)
    }
    return slot
  }

  private armSlotTimer(slot: MountSlot, delayMs: number): void {
    if (this.stopping || slot.key.startsWith('library_') || this.slots.get(slot.key) !== slot) return
    slot.clearIdle()
    const timer = setTimeout(() => {
      slot.idle = undefined
      void this.expireSlot(slot)
    }, delayMs)
    timer.unref()
    slot.idle = timer
  }

  private maybeDeleteIdleSlot(slot: MountSlot): void {
    if (!slot.live && !slot.uncertain && !slot.idle && slot.inFlight <= 1 && this.slots.get(slot.key) === slot) {
      this.slots.delete(slot.key)
    }
  }

  private async rcUnmount(mountPoint: string): Promise<void> {
    await this.rc('mount/unmount', { mountPoint }, AbortSignal.timeout(this.cfg.mountTimeoutMs)).catch(error => {
      if (!isMountNotFoundError(error)) throw error
    })
  }

  private async start(): Promise<void> {
    for (const path of [this.cfg.root, this.cfg.cache, dirname(this.cfg.socket)]) {
      await mkdir(path, { recursive: true, mode: 0o700 })
      await chmod(path, 0o700)
    }
    if (this.cfg.configureSystemDirs) {
      for (const path of ['/drive', '/drive-recovery']) await mkdir(path, { recursive: true, mode: 0o755 })
    }
    await this.unmountKernelMounts(this.cfg.root, true)
    await rm(this.cfg.socket, { force: true })
    const daemon = this.cfg.spawnDaemon(this.cfg.socket, this.cfg.cache)
    this.daemon = daemon
    void daemon.exited.then(() => {
      if (this.daemon === daemon && !this.stopping) this.cfg.onUnexpectedDaemonExit()
    })
    const deadline = Date.now() + 15_000
    for (;;) {
      try {
        await this.rc('core/version', {})
        await chmod(this.cfg.socket, 0o600)
        return
      } catch (error) {
        if (daemon.exitCode !== null || Date.now() >= deadline) {
          if (this.daemon === daemon) this.daemon = undefined
          daemon.kill()
          throw error
        }
        await Bun.sleep(50)
      }
    }
  }

  private mount(key: string, url: string, token: string, recovery: string): Promise<Mount> {
    const slot = this.getOrCreateSlot(key)
    return slot.run(async () => {
      if (this.stopping) throw new Error('Drive mounts are stopping')
      if (this.slots.get(key) !== slot) this.slots.set(key, slot)
      slot.clearIdle()

      if (slot.live && !slot.uncertain) {
        const mount = slot.live
        mount.token = token
        mount.references++
        try {
          await this.rc('ankole/configure', { fs: key, token, recovery })
          return mount
        } catch (error) {
          this.releaseOnSlot(slot, mount)
          throw error
        }
      }

      if (slot.live) {
        clearInterval(slot.live.refresh)
        slot.live = undefined
      }

      try {
        const path = slot.path
        await mkdir(path, { recursive: true, mode: 0o700 })
        const resolvedPath = await this.cfg.realpath(path).catch(() => path)
        // `mount/listmounts` acquires rclone's global `mountMu`, so any earlier
        // `mount/mount` or `mount/unmount` that outlived its HTTP client timeout settles before we inspect.
        const { mountPoints } = await this.rc<{ mountPoints?: Array<{ Fs: string; MountPoint: string }> }>(
          'mount/listmounts',
          {},
          AbortSignal.timeout(this.cfg.mountTimeoutMs)
        )
        let adopted = false
        const existing = mountPoints?.find(item => item.MountPoint === path || item.MountPoint === resolvedPath)
        if (existing) {
          slot.uncertain = true
          try {
            await this.rc('ankole/invalidate-all-clean', { fs: key })
            await this.rc('ankole/configure', { fs: key, token, recovery })
            await stat(path)
            adopted = true
          } catch {
            await this.rcUnmount(existing.MountPoint)
            slot.uncertain = false
          }
        } else {
          slot.uncertain = false
        }

        if (!adopted) {
          await this.unmountKernelMounts(path, true)
          await mkdir(path, { recursive: true, mode: 0o700 })
          await this.rc('config/create', {
            name: key,
            type: 'webdav',
            parameters: {
              url,
              vendor: 'ankole',
              bearer_token: token,
              ...(key.startsWith('library_') ? { headers: 'X-Ankole-Library,1' } : {}),
              ...(key.startsWith('scope_') ? { headers: 'X-Ankole-Shared-Scope,1' } : {})
            }
          })
          slot.uncertain = true
          await this.rc(
            'mount/mount',
            {
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
            },
            AbortSignal.timeout(this.cfg.mountTimeoutMs)
          )
        }

        if (this.stopping || this.slots.get(key) !== slot) throw new Error('Drive mounts stopped')

        const mount: Mount = { key, path, references: 1, token, endpoint: url }
        mount.refresh = setInterval(
          () => void this.refresh(mount).catch(error => console.error('Drive token refresh failed:', error)),
          20 * 60_000
        )
        mount.refresh.unref()
        slot.live = mount
        slot.uncertain = false

        if (!adopted) {
          try {
            await this.rc('ankole/configure', { fs: key, token, recovery })
          } catch (error) {
            this.releaseOnSlot(slot, mount)
            throw error
          }
        }
        return mount
      } catch (error) {
        if (!slot.live && !this.stopping && this.slots.get(key) === slot) {
          if (slot.uncertain) this.armSlotTimer(slot, this.cfg.orphanIdleTimeoutMs)
          else this.maybeDeleteIdleSlot(slot)
        }
        throw error
      }
    })
  }

  private expireSlot(slot: MountSlot): Promise<void> {
    return slot.run(async () => {
      if (this.stopping || this.slots.get(slot.key) !== slot) return
      if (slot.live && slot.live.references > 0) return
      if (!slot.live && !slot.uncertain) {
        this.maybeDeleteIdleSlot(slot)
        return
      }
      slot.clearIdle()

      if (slot.live) {
        try {
          const pending = await this.rc<{ count: number }>(
            'ankole/pending',
            { fs: slot.key },
            AbortSignal.timeout(this.cfg.mountTimeoutMs)
          )
          if (this.stopping || (slot.live && slot.live.references > 0)) return
          if (pending.count > 0) {
            this.armSlotTimer(slot, this.cfg.retryIdleTimeoutMs)
            return
          }
        } catch {
          if (!this.stopping && slot.live && slot.live.references === 0) {
            this.armSlotTimer(slot, this.cfg.retryIdleTimeoutMs)
          }
          return
        }

        // Demote `slot.live` before issuing `mount/unmount`: once an unmount call
        // starts, no subsequent `acquire()` may reuse this entry without reconciling.
        clearInterval(slot.live.refresh)
        slot.live = undefined
        slot.uncertain = true
      }

      const path = slot.path
      const resolvedPath = await this.cfg.realpath(path).catch(() => path)
      if (this.stopping || this.slots.get(slot.key) !== slot) return

      try {
        await this.rcUnmount(path)
        if (resolvedPath !== path) await this.rcUnmount(resolvedPath)
        await this.unmountKernelMounts(path, true)
        slot.uncertain = false
        this.maybeDeleteIdleSlot(slot)
      } catch {
        const listed = await this.rc<{ mountPoints?: Array<{ MountPoint: string }> }>(
          'mount/listmounts',
          {},
          AbortSignal.timeout(this.cfg.mountTimeoutMs)
        ).catch(() => undefined)
        if (listed && !listed.mountPoints?.some(item => item.MountPoint === path || item.MountPoint === resolvedPath)) {
          await this.unmountKernelMounts(path, true)
          slot.uncertain = false
          this.maybeDeleteIdleSlot(slot)
          return
        }
        slot.uncertain = true
        if (!this.stopping && this.slots.get(slot.key) === slot) {
          this.armSlotTimer(slot, this.cfg.retryIdleTimeoutMs)
        }
      }
    })
  }

  private async unmountKernelMounts(targetPath: string, includeDescendants: boolean): Promise<void> {
    let mountinfo: string
    try {
      mountinfo = await readFile(this.cfg.mountInfoPath, 'utf8')
    } catch {
      return
    }
    const resolvedTarget = await this.cfg.realpath(targetPath).catch(() => targetPath)
    const candidates = parseMountPointsUnder(mountinfo, targetPath, includeDescendants)
    if (resolvedTarget !== targetPath) {
      for (const extra of parseMountPointsUnder(mountinfo, resolvedTarget, includeDescendants)) {
        if (!candidates.includes(extra)) candidates.push(extra)
      }
    }
    for (const mountPoint of candidates) {
      await this.cfg.lazyUnmount(mountPoint).catch(() => undefined)
    }
  }

  private async refresh(mount: Mount): Promise<void> {
    const endpoint = new URL('/api/v1/vfs/refresh', mount.endpoint)
    const response = await fetch(endpoint, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${mount.token}`,
        ...(mount.key.startsWith('library_') ? { 'x-ankole-library': '1' } : {})
      },
      signal: AbortSignal.timeout(15_000)
    })
    if (!response.ok) throw new Error(`Drive credential refresh: HTTP ${response.status}`)
    const { token } = (await response.json()) as { token: string }
    await this.rc('ankole/configure', {
      fs: mount.key,
      token,
      upload_limit: Number(response.headers.get('x-ankole-upload-limit'))
    })
    mount.token = token
  }

  private releaseOnSlot(slot: MountSlot, mount: Mount): void {
    mount.references = Math.max(0, mount.references - 1)
    if (
      mount.references === 0 &&
      !mount.key.startsWith('library_') &&
      !this.stopping &&
      this.slots.get(slot.key) === slot &&
      slot.live === mount &&
      !slot.uncertain
    ) {
      this.armSlotTimer(slot, this.cfg.idleTimeoutMs)
    }
  }

  private async release(mount: Mount): Promise<void> {
    const slot = this.slots.get(mount.key)
    if (slot) this.releaseOnSlot(slot, mount)
  }
}

function waitForProcessExit(exited: Promise<unknown>, timeoutMs: number): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined
  return Promise.race([
    exited.then(
      () => true,
      () => true
    ),
    new Promise<boolean>(resolve => {
      timer = setTimeout(() => resolve(false), timeoutMs)
      timer.unref?.()
    })
  ]).finally(() => {
    if (timer) clearTimeout(timer)
  })
}

export const driveMounts = new DriveMounts()
