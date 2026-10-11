import type { DirectoryBackupRecord } from '@cloudflare/sandbox'
import type { ContainerControl, HomeBackups, RegistryControl, WorkerStorage } from '../src/types'

// Shape: @cloudflare/sandbox 1.0.0 DirectoryBackupRecord, also documented at
// https://developers.cloudflare.com/sandbox/reference/directory-backups/
export const backupRecord: DirectoryBackupRecord = {
  id: '019a7e50-0361-7bc0-8ef1-48a7b3f4c5d6',
  dir: '/workspace',
  size: 1024,
  sha256: 'a'.repeat(64),
  format: 'tar+zstd/1'
}

export class FakeStorage implements WorkerStorage {
  readonly values = new Map<string, unknown>()
  alarm: number | undefined
  async get<T>(key: string): Promise<T | undefined> {
    return structuredClone(this.values.get(key)) as T | undefined
  }
  async put(key: string | Record<string, unknown>, value?: unknown): Promise<void> {
    if (typeof key === 'string') this.values.set(key, structuredClone(value))
    else for (const [name, item] of Object.entries(key)) this.values.set(name, structuredClone(item))
  }
  async delete(key: string): Promise<void> {
    this.values.delete(key)
  }
  async setAlarm(time: number): Promise<void> {
    this.alarm = time
  }
  async deleteAlarm(): Promise<void> {
    this.alarm = undefined
  }
}

export class FakeContainer implements ContainerControl {
  running = false
  images: Record<string, string> = { 'worker-a': 'registry.cloudflare.com/acct/worker@sha256:aaa' }
  readonly starts: Record<string, unknown>[] = []
  readonly signals: number[] = []
  readonly timeouts: number[] = []
  destroyed = 0
  private exits: Array<(error?: Error) => void> = []
  start(options: Record<string, unknown>): void {
    this.starts.push(options)
    this.running = true
  }
  signal(signal: number): void {
    this.signals.push(signal)
  }
  monitor(): Promise<unknown> {
    if (!this.running) return Promise.resolve()
    return new Promise((resolve, reject) => this.exits.push(error => (error ? reject(error) : resolve(undefined))))
  }
  async setInactivityTimeout(durationMs: number): Promise<void> {
    if (durationMs <= 0 || durationMs > 6 * 60 * 60 * 1000) throw new Error('invalid inactivity timeout')
    this.timeouts.push(durationMs)
  }
  async destroy(): Promise<void> {
    this.destroyed += 1
    this.exit(new Error('container destroyed'))
  }
  exit(error?: Error): void {
    this.running = false
    for (const settle of this.exits.splice(0)) settle(error)
  }
}

export class FakeRegistry implements RegistryControl {
  readonly entries = new Map<string, string>()
  async add(uid: string, provider: string): Promise<void> {
    this.entries.set(uid, provider)
  }
  async remove(uid: string, provider: string): Promise<void> {
    if (this.entries.get(uid) === provider) this.entries.delete(uid)
  }
}

export class FakeBackups implements HomeBackups {
  readonly restores: Array<[string, DirectoryBackupRecord]> = []
  readonly backups: string[] = []
  readonly removals: Array<[string, DirectoryBackupRecord | null]> = []
  async restore(uid: string, record: DirectoryBackupRecord): Promise<void> {
    this.restores.push([uid, record])
  }
  async backup(uid: string): Promise<DirectoryBackupRecord> {
    this.backups.push(uid)
    return backupRecord
  }
  async removeOthers(uid: string, keep: DirectoryBackupRecord | null): Promise<void> {
    this.removals.push([uid, keep])
  }
}
