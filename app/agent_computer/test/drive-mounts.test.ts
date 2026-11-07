import { create } from '@bufbuild/protobuf'
import { afterEach, describe, expect, it } from 'bun:test'
import { existsSync, realpathSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { realpath as fsRealpath } from 'node:fs/promises'
import { createServer, type Server } from 'node:http'
import { join } from 'node:path'
import { DriveMounts, type DriveMountsOptions, parseMountPointsUnder } from '../src/drive/mounts'
import { DriveVfsConfigSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/envelope_pb'

type FakeRcdOptions = {
  onMount?: (fs: string, mountPoint: string, attempt: number) => Promise<void> | void
  onUnmount?: (mountPoint: string) => Promise<void> | void
  onListMounts?: (callIndex: number) => Promise<void> | void
  failInvalidateKeys?: Set<string>
}

class FakeRcd {
  readonly calls: Array<{ method: string; body: Record<string, unknown> }> = []
  readonly liveMounts = new Map<string, string>()
  readonly remotes = new Map<string, Record<string, unknown>>()
  readonly tokens = new Map<string, string>()
  private mountMutex = Promise.resolve()
  private mountAttempts = new Map<string, number>()
  private listMountsCount = 0
  private server?: Server

  constructor(private readonly options: FakeRcdOptions = {}) {}

  private withMountLock<T>(fn: () => Promise<T>): Promise<T> {
    const next = this.mountMutex.then(fn, fn)
    this.mountMutex = next.then(
      () => undefined,
      () => undefined
    )
    return next
  }

  async listen(socketPath: string): Promise<void> {
    if (existsSync(socketPath)) {
      throw new Error(`listen EADDRINUSE: address already in use ${socketPath}`)
    }
    const server = createServer((req, res) => {
      const chunks: Buffer[] = []
      req.on('data', chunk => chunks.push(chunk))
      req.on('end', () => {
        void (async () => {
          const method = (req.url ?? '/').replace(/^\//, '')
          const raw = Buffer.concat(chunks).toString()
          const body = (raw ? JSON.parse(raw) : {}) as Record<string, unknown>
          this.calls.push({ method, body })
          try {
            const payload = await this.dispatch(method, body)
            if (!res.destroyed) {
              res.writeHead(200, { 'content-type': 'application/json' })
              res.end(JSON.stringify(payload))
            }
          } catch (error) {
            if (!res.destroyed) {
              res.writeHead(500, { 'content-type': 'application/json' })
              res.end(JSON.stringify({ error: error instanceof Error ? error.message : String(error) }))
            }
          }
        })()
      })
    })
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject)
      server.listen(socketPath, () => resolve())
    })
    this.server = server
  }

  async close(): Promise<void> {
    const server = this.server
    this.server = undefined
    if (!server) return
    await new Promise<void>(resolve => server.close(() => resolve()))
  }

  private async dispatch(method: string, body: Record<string, unknown>): Promise<Record<string, unknown>> {
    switch (method) {
      case 'core/version':
        return { version: 'v1.75.2-ankole' }
      case 'config/create': {
        const name = String(body.name)
        const parameters = (body.parameters ?? {}) as Record<string, unknown>
        this.remotes.set(name, parameters)
        if (typeof parameters.bearer_token === 'string') {
          this.tokens.set(name, parameters.bearer_token)
        }
        return {}
      }
      case 'mount/listmounts':
        return this.withMountLock(async () => {
          const callIndex = ++this.listMountsCount
          await this.options.onListMounts?.(callIndex)
          return {
            mountPoints: [...this.liveMounts.entries()].map(([mountPoint, fs]) => ({
              Fs: fs,
              MountPoint: mountPoint,
              MountedOn: new Date().toISOString()
            }))
          }
        })
      case 'mount/mount':
        return this.withMountLock(async () => {
          const fs = String(body.fs)
          const mountPoint = String(body.mountPoint)
          const attempt = (this.mountAttempts.get(mountPoint) ?? 0) + 1
          this.mountAttempts.set(mountPoint, attempt)
          if (this.liveMounts.has(mountPoint)) {
            throw new Error(
              `failed to mount FUSE fs: directory already mounted, use --allow-non-empty to mount anyway: ${mountPoint}`
            )
          }
          await this.options.onMount?.(fs, mountPoint, attempt)
          this.liveMounts.set(mountPoint, fs)
          return { mountPoint }
        })
      case 'mount/unmount':
        return this.withMountLock(async () => {
          const mountPoint = String(body.mountPoint)
          if (!this.liveMounts.has(mountPoint)) throw new Error('mount not found')
          await this.options.onUnmount?.(mountPoint)
          this.liveMounts.delete(mountPoint)
          return {}
        })
      case 'mount/unmountall':
        return this.withMountLock(async () => {
          for (const mountPoint of this.liveMounts.keys()) {
            await this.options.onUnmount?.(mountPoint)
            this.liveMounts.delete(mountPoint)
          }
          return {}
        })
      case 'ankole/invalidate-all-clean':
      case 'ankole/invalidate': {
        const key = String(body.fs)
        if (this.options.failInvalidateKeys?.has(key)) throw new Error('mount is not attached')
        return {}
      }
      case 'ankole/configure': {
        const key = String(body.fs)
        if (typeof body.token === 'string') this.tokens.set(key, body.token)
        return {}
      }
      case 'ankole/pending':
        return { count: 0 }
      case 'ankole/sequence':
        return { sequence: 1 }
      default:
        throw new Error(`Unhandled rc method: ${method}`)
    }
  }
}

const tempDirs: string[] = []
const servers: FakeRcd[] = []
const childProcs: Array<ReturnType<typeof Bun.spawn>> = []
const mountsInstances: DriveMounts[] = []

afterEach(async () => {
  for (const mounts of mountsInstances.splice(0)) {
    await mounts.stop(100, 100).catch(() => undefined)
  }
  for (const rcd of servers.splice(0)) await rcd.close()
  for (const proc of childProcs.splice(0)) {
    proc.kill('SIGKILL')
    await proc.exited.catch(() => undefined)
  }
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true })
})

function makeFixtureDir(): string {
  const dir = realpathSync(mkdtempSync('/tmp/adm-'))
  tempDirs.push(dir)
  return dir
}

function sampleConfig(token = 'token-1') {
  return create(DriveVfsConfigSchema, {
    token,
    endpoint: 'https://console.ankole.test/api/v1/vfs/dav',
    scope: 's1',
    view: '6475f5a53031a7a9',
    conversationId: '2565fde7-4b4a-4f2b-9f2e-3c258445d79c',
    libraryScope: 'l1'
  })
}

function spawnIdleHelper(): ReturnType<typeof Bun.spawn> {
  const proc = Bun.spawn([process.execPath, '-e', 'setInterval(() => {}, 1000)'], {
    stdin: 'ignore',
    stdout: 'ignore',
    stderr: 'ignore'
  })
  childProcs.push(proc)
  return proc
}

function createTestMounts(rcd: FakeRcd, options: DriveMountsOptions): DriveMounts {
  const mounts = new DriveMounts({
    isRoot: () => true,
    onUnexpectedDaemonExit: () => {},
    spawnDaemon: socketPath => {
      const proc = spawnIdleHelper()
      void rcd.listen(socketPath)
      return proc
    },
    ...options
  })
  mountsInstances.push(mounts)
  return mounts
}

describe('parseMountPointsUnder', () => {
  it('decodes mountinfo escapes without double-unescaping and returns reverse mount order', () => {
    const mountinfo = [
      '36 25 0:31 / /run rw,nosuid - tmpfs tmpfs rw',
      '91 36 0:55 / /run/ankole-drives/scope_s1 rw - fuse.rclone scope_s1: rw',
      '92 36 0:56 / /run/ankole-drives/chat\\040space rw - fuse.rclone chat: rw',
      '93 36 0:57 / /run/ankole-drives/chat\\134040literal rw - fuse.rclone chat2: rw',
      '94 91 0:58 / /run/ankole-drives/scope_s1/child rw - fuse.rclone child: rw',
      '95 36 0:59 / /run/ankole-drives/scope_s1 rw - fuse.rclone stacked: rw',
      '96 36 0:60 / /run/ankole-drives-other/ignored rw - fuse.rclone other: rw'
    ].join('\n')

    expect(parseMountPointsUnder(mountinfo, '/run/ankole-drives')).toEqual([
      '/run/ankole-drives/scope_s1',
      '/run/ankole-drives/scope_s1/child',
      '/run/ankole-drives/chat\\040literal',
      '/run/ankole-drives/chat space',
      '/run/ankole-drives/scope_s1'
    ])
  })
})

describe('DriveMounts FUSE lifecycle and recovery', () => {
  it('adopts a background-completed mount on retry after client mount/mount timeout instead of failing with directory already mounted', async () => {
    const dir = makeFixtureDir()
    const root = join(dir, 'drives')
    const cache = join(dir, 'cache')
    const socket = join(dir, 'rc.sock')
    const mountInfoPath = join(dir, 'mountinfo')
    writeFileSync(mountInfoPath, '')

    const rcd = new FakeRcd({
      onMount: async (fs, _mountPoint, attempt) => {
        if (fs.startsWith('chat_') && attempt === 1) {
          // Exceed client mountTimeoutMs (60ms) while completing in rcd within the
          // retry's mount/listmounts window (~30ms remaining on mountMutex).
          await Bun.sleep(90)
        }
      }
    })
    servers.push(rcd)

    const mounts = createTestMounts(rcd, {
      root,
      cache,
      socket,
      mountTimeoutMs: 60,
      mountInfoPath
    })

    // First attempt aborts at 60ms while rcd is still mounting `chat_<view>`.
    await expect(mounts.acquire(sampleConfig('token-initial'))).rejects.toThrow(/aborted|Timeout/i)

    // Retry immediately: `mount/listmounts` waits on rcd's `mountMu`, sees the
    // finished `chat_<view>` mount, refreshes its token, and adopts it cleanly.
    const view = await mounts.acquire(sampleConfig('token-retry'))
    expect(view).toBeDefined()
    expect(view!.chat?.path).toBe(join(root, 'chat_6475f5a53031a7a9'))
    expect(rcd.tokens.get('chat_6475f5a53031a7a9')).toBe('token-retry')
    expect(
      rcd.calls.filter(call => call.method === 'mount/mount' && call.body.fs === 'chat_6475f5a53031a7a9:')
    ).toHaveLength(1)

    await view!.release()
    await mounts.stop()
    expect(rcd.liveMounts.size).toBe(0)
  })

  it('unmounts an unattached liveMount and remounts cleanly when adoption probe fails', async () => {
    const dir = makeFixtureDir()
    const root = join(dir, 'drives')
    const cache = join(dir, 'cache')
    const socket = join(dir, 'rc.sock')
    const chatPath = join(root, 'chat_6475f5a53031a7a9')
    mkdirSync(chatPath, { recursive: true })

    const failInvalidateKeys = new Set(['chat_6475f5a53031a7a9'])
    const rcd = new FakeRcd({
      failInvalidateKeys,
      onUnmount: () => {
        failInvalidateKeys.delete('chat_6475f5a53031a7a9')
      }
    })
    rcd.liveMounts.set(chatPath, 'chat_6475f5a53031a7a9:')
    servers.push(rcd)

    const mounts = createTestMounts(rcd, {
      root,
      cache,
      socket,
      mountInfoPath: join(dir, 'mountinfo')
    })

    const view = await mounts.acquire(sampleConfig('token-fresh'))
    expect(view?.chat?.path).toBe(chatPath)
    expect(rcd.calls.some(call => call.method === 'mount/unmount' && call.body.mountPoint === chatPath)).toBe(true)
    expect(rcd.calls.some(call => call.method === 'mount/mount' && call.body.mountPoint === chatPath)).toBe(true)

    await view!.release()
    await mounts.stop()
  })

  it('detaches stale kernel mounts from /proc/self/mountinfo and removes stale rclone.sock before starting and mounting', async () => {
    const dir = makeFixtureDir()
    const root = join(dir, 'drives')
    const cache = join(dir, 'cache')
    const socket = join(dir, 'rc.sock')
    const mountInfoPath = join(dir, 'mountinfo')
    mkdirSync(dir, { recursive: true })
    // Simulate a leftover socket file and dead ENOTCONN FUSE mount from a SIGKILLed ankole-rclone.
    writeFileSync(socket, 'stale-socket')
    const staleChatMount = join(root, 'chat_6475f5a53031a7a9')
    const staleScopeMount = join(root, 'scope_s1')
    const kernelMounted = new Set([staleScopeMount, staleChatMount])
    const renderMountInfo = () =>
      [...kernelMounted].map((mp, idx) => `${100 + idx} 36 0:${50 + idx} / ${mp} rw - fuse.rclone stale: rw`).join('\n')
    writeFileSync(mountInfoPath, renderMountInfo())

    const lazyUnmounted: string[] = []
    const rcd = new FakeRcd({
      onMount: (_fs, mountPoint) => {
        if (kernelMounted.has(mountPoint)) {
          throw new Error(
            `failed to mount FUSE fs: directory already mounted, use --allow-non-empty to mount anyway: ${mountPoint}`
          )
        }
      }
    })
    servers.push(rcd)

    const mounts = createTestMounts(rcd, {
      root,
      cache,
      socket,
      mountInfoPath,
      lazyUnmount: async mountPoint => {
        lazyUnmounted.push(mountPoint)
        kernelMounted.delete(mountPoint)
        writeFileSync(mountInfoPath, renderMountInfo())
      }
    })

    const view = await mounts.acquire(sampleConfig())
    expect(view).toBeDefined()
    expect(lazyUnmounted).toEqual([staleChatMount, staleScopeMount])
    expect(kernelMounted.size).toBe(0)

    // Inject another stale kernel mount entry before stop() to verify stop() sweeps it too.
    kernelMounted.add(staleChatMount)
    writeFileSync(mountInfoPath, renderMountInfo())

    await view!.release()
    await mounts.stop()
    expect(kernelMounted.size).toBe(0)
    expect(existsSync(socket)).toBe(false)
  })

  it('reaps an unclaimed background mount after orphanIdleTimeoutMs when no caller retries', async () => {
    const dir = makeFixtureDir()
    const root = join(dir, 'drives')
    const cache = join(dir, 'cache')
    const socket = join(dir, 'rc.sock')
    const chatPath = join(root, 'chat_6475f5a53031a7a9')

    const rcd = new FakeRcd({
      onMount: async (fs, _mountPoint, attempt) => {
        if (fs.startsWith('chat_') && attempt === 1) await Bun.sleep(90)
      }
    })
    servers.push(rcd)

    const mounts = createTestMounts(rcd, {
      root,
      cache,
      socket,
      mountTimeoutMs: 40,
      orphanIdleTimeoutMs: 140,
      mountInfoPath: join(dir, 'mountinfo')
    })

    await expect(mounts.acquire(sampleConfig())).rejects.toThrow(/aborted|Timeout/i)
    await Bun.sleep(80)
    expect(rcd.liveMounts.has(chatPath)).toBe(true)

    await Bun.sleep(110)
    expect(rcd.liveMounts.has(chatPath)).toBe(false)

    await mounts.stop()
  })

  it('evicts a Mount entry when both idle mount/unmount and follow-up mount/listmounts time out before rcd finishes unmounting', async () => {
    const dir = makeFixtureDir()
    const root = join(dir, 'drives')
    const cache = join(dir, 'cache')
    const socket = join(dir, 'rc.sock')
    const chatPath = join(root, 'chat_6475f5a53031a7a9')

    const rcd = new FakeRcd({
      onUnmount: async mountPoint => {
        // 100ms exceeds BOTH mount/unmount (40ms) AND the catch-branch mount/listmounts (40ms).
        if (mountPoint.includes('chat_')) await Bun.sleep(100)
      }
    })
    servers.push(rcd)

    const mounts = createTestMounts(rcd, {
      root,
      cache,
      socket,
      mountTimeoutMs: 40,
      idleTimeoutMs: 30,
      retryIdleTimeoutMs: 60_000,
      mountInfoPath: join(dir, 'mountinfo')
    })

    const first = await mounts.acquire(sampleConfig('token-1'))
    await first!.release()
    // Wait for idle timer (30ms) + slow unmount in rcd (100ms), before retryIdleTimeoutMs (60s) fires.
    await Bun.sleep(180)
    expect(rcd.liveMounts.has(chatPath)).toBe(false)

    // Re-acquiring must reconcile and mount `chat_<view>` fresh rather than leasing the unmounted Mount.
    const second = await mounts.acquire(sampleConfig('token-2'))
    expect(second).toBeDefined()
    expect(rcd.liveMounts.has(chatPath)).toBe(true)
    expect(second!.chat?.references).toBe(1)
    expect(
      rcd.calls.filter(call => call.method === 'mount/mount' && call.body.fs === 'chat_6475f5a53031a7a9:')
    ).toHaveLength(2)

    await second!.release()
    await mounts.stop()
  })

  it('serializes orphan cleanup with concurrent acquire across async boundaries so an adopted mount is never unmounted', async () => {
    // Subcase A: orphan cleanup starts first and suspends at realpath while a new acquire() arrives.
    {
      const dir = makeFixtureDir()
      const root = join(dir, 'drives')
      const cache = join(dir, 'cache')
      const socket = join(dir, 'rc.sock')
      const chatPath = join(root, 'chat_6475f5a53031a7a9')

      let pauseNextChatRealpath = false
      let releasePausedRealpath!: () => void
      let notifyPausedRealpath!: () => void
      const pausedAtRealpath = new Promise<void>(resolve => {
        notifyPausedRealpath = resolve
      })
      const resumeGate = new Promise<void>(resolve => {
        releasePausedRealpath = resolve
      })

      const rcd = new FakeRcd({
        onMount: async (fs, _mountPoint, attempt) => {
          if (fs.startsWith('chat_') && attempt === 1) await Bun.sleep(70)
        }
      })
      servers.push(rcd)

      const mounts = createTestMounts(rcd, {
        root,
        cache,
        socket,
        mountTimeoutMs: 35,
        orphanIdleTimeoutMs: 70,
        mountInfoPath: join(dir, 'mountinfo'),
        realpath: async target => {
          if (pauseNextChatRealpath && target === chatPath) {
            pauseNextChatRealpath = false
            notifyPausedRealpath()
            await resumeGate
          }
          return fsRealpath(target)
        }
      })

      await expect(mounts.acquire(sampleConfig('token-1'))).rejects.toThrow(/aborted|Timeout/i)
      // Wait until background mount finishes (70ms from start -> ~35ms more), then arm realpath pause for orphan cleanup.
      await Bun.sleep(45)
      expect(rcd.liveMounts.has(chatPath)).toBe(true)
      pauseNextChatRealpath = true

      // Wait until orphan cleanup enters expireSlot and suspends at realpath(chatPath).
      await pausedAtRealpath

      // Start concurrent acquire() while orphan cleanup is mid-flight, then resume realpath.
      const acquiring = mounts.acquire(sampleConfig('token-2'))
      await Bun.sleep(15)
      releasePausedRealpath()

      const view = await acquiring
      expect(view).toBeDefined()
      expect(rcd.liveMounts.has(chatPath)).toBe(true)
      expect(view!.chat?.references).toBe(1)

      await view!.release()
      await mounts.stop()
    }

    // Subcase B: acquire() enters the slot first and suspends at realpath while the orphan timer fires behind it.
    {
      const dir = makeFixtureDir()
      const root = join(dir, 'drives')
      const cache = join(dir, 'cache')
      const socket = join(dir, 'rc.sock')
      const chatPath = join(root, 'chat_6475f5a53031a7a9')

      let pauseAcquireRealpath = false
      let releaseAcquireRealpath!: () => void
      let notifyAcquirePaused!: () => void
      const acquirePaused = new Promise<void>(resolve => {
        notifyAcquirePaused = resolve
      })
      const acquireGate = new Promise<void>(resolve => {
        releaseAcquireRealpath = resolve
      })

      const rcd = new FakeRcd({
        onMount: async (fs, _mountPoint, attempt) => {
          if (fs.startsWith('chat_') && attempt === 1) await Bun.sleep(70)
        }
      })
      servers.push(rcd)

      const mounts = createTestMounts(rcd, {
        root,
        cache,
        socket,
        mountTimeoutMs: 35,
        orphanIdleTimeoutMs: 80,
        mountInfoPath: join(dir, 'mountinfo'),
        realpath: async target => {
          if (pauseAcquireRealpath && target === chatPath) {
            pauseAcquireRealpath = false
            notifyAcquirePaused()
            await acquireGate
          }
          return fsRealpath(target)
        }
      })

      await expect(mounts.acquire(sampleConfig('token-1'))).rejects.toThrow(/aborted|Timeout/i)
      await Bun.sleep(45)
      expect(rcd.liveMounts.has(chatPath)).toBe(true)

      pauseAcquireRealpath = true
      const acquiring = mounts.acquire(sampleConfig('token-2'))
      await acquirePaused

      // Let orphanIdleTimeoutMs fire (if not cancelled) while acquire() is suspended at realpath.
      await Bun.sleep(60)
      releaseAcquireRealpath()

      const view = await acquiring
      await Bun.sleep(30)
      expect(view).toBeDefined()
      expect(rcd.liveMounts.has(chatPath)).toBe(true)
      expect(view!.chat?.references).toBe(1)

      await view!.release()
      await mounts.stop()
    }
  })

  it('retains orphan cleanup responsibility when a retry fails during mount/listmounts', async () => {
    const dir = makeFixtureDir()
    const root = join(dir, 'drives')
    const cache = join(dir, 'cache')
    const socket = join(dir, 'rc.sock')
    const chatPath = join(root, 'chat_6475f5a53031a7a9')

    let stallNextListMounts = false
    const rcd = new FakeRcd({
      onMount: async (fs, _mountPoint, attempt) => {
        if (fs.startsWith('chat_') && attempt === 1) await Bun.sleep(70)
      },
      onListMounts: async () => {
        if (stallNextListMounts) {
          stallNextListMounts = false
          await Bun.sleep(80)
        }
      }
    })
    servers.push(rcd)

    const mounts = createTestMounts(rcd, {
      root,
      cache,
      socket,
      mountTimeoutMs: 35,
      orphanIdleTimeoutMs: 110,
      mountInfoPath: join(dir, 'mountinfo')
    })

    // Attempt 1 times out on chat_<view> mount/mount, marking the slot uncertain and arming orphan cleanup.
    await expect(mounts.acquire(sampleConfig('token-1'))).rejects.toThrow(/aborted|Timeout/i)
    await Bun.sleep(50)
    expect(rcd.liveMounts.has(chatPath)).toBe(true)

    // Attempt 2 arrives before orphanIdleTimeoutMs fires, and fails on mount/listmounts timeout for chat_<view>.
    // Note: scope_s1 is already live in its slot, so the first listmounts call during Attempt 2 is for chat_<view>!
    stallNextListMounts = true
    await expect(mounts.acquire(sampleConfig('token-2'))).rejects.toThrow(/aborted|Timeout/i)

    // No further acquire() calls arrive; the slot must still reap the orphaned chat_<view> mount.
    await Bun.sleep(170)
    expect(rcd.liveMounts.has(chatPath)).toBe(false)

    await mounts.stop()
  })
})
