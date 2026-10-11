import type { DirectoryBackupRecord } from '@cloudflare/sandbox'

export type Instance = string | { vcpu: number; memoryMib: number; diskMb: number }

export interface Contract {
  providerId: string
  agentUid: string
  generation: string
  image: string
  env: Record<string, string>
  instance: Instance
  storageRef: DirectoryBackupRecord | null
}

export interface DeleteRequest {
  mode: 'graceful' | 'now'
  graceSeconds: number
}

export type Phase = 'starting' | 'running' | 'terminating'

export interface WorkerObject {
  agent_uid: string
  generation: string
  phase: Phase
  reason: string | null
  started_at: string
}

export interface StorageObservation {
  storage_ref: DirectoryBackupRecord | null
  reason: string | null
}

export type Result<T> = { ok: true; value: T } | { ok: false; status: number; code: string; message: string }

export interface ContainerControl {
  readonly running: boolean
  readonly images: Readonly<Record<string, string>>
  start(options: { image: string; enableInternet: boolean; env: Record<string, string>; instance: Instance }): void
  signal(signal: number): void
  monitor(): Promise<unknown>
  destroy(error?: unknown): Promise<unknown>
  setInactivityTimeout(durationMs: number): Promise<unknown>
}

export interface WorkerStorage {
  get<T>(key: string): Promise<T | undefined>
  put(key: string, value: unknown): Promise<unknown>
  put(values: Record<string, unknown>): Promise<unknown>
  delete(key: string): Promise<unknown>
  setAlarm(scheduledTime: number): Promise<unknown>
  deleteAlarm(): Promise<unknown>
}

export interface RegistryControl {
  add(agentUid: string, providerId: string): Promise<unknown>
  remove(agentUid: string, providerId: string): Promise<unknown>
}

/** Unit tests fake this SDK/R2 boundary. Production uses DirectoryBackup. */
export interface HomeBackups {
  restore(agentUid: string, record: DirectoryBackupRecord): Promise<void>
  backup(agentUid: string): Promise<DirectoryBackupRecord>
  removeOthers(agentUid: string, keep: DirectoryBackupRecord | null): Promise<void>
}

export class AdapterError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string
  ) {
    super(message)
    this.name = 'AdapterError'
  }
}

export function authorized(header: string | null, token: string): boolean {
  const expected = `Bearer ${token}`
  if (!token || header === null || header.length !== expected.length) return false
  let difference = 0
  for (let index = 0; index < expected.length; index += 1) {
    difference |= header.charCodeAt(index) ^ expected.charCodeAt(index)
  }
  return difference === 0
}
