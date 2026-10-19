import { readFileSync } from 'node:fs'
import { writeFile, rm } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { resolve } from 'node:path'
import { requestSocketLineBridge } from '../core/socket-line-client'

const contextFileEnv = 'ANKOLE_RUNTIME_AUTOMATION_JOB_CONTEXT_FILE'
const emitSocketEnv = 'ANKOLE_RUNTIME_AUTOMATION_JOB_EMIT_SOCKET'

export type AutomationJobContext = {
  event: Record<string, unknown>
  job: {
    id: number
    label: string
  }
}

const contextValue = readContext()
const runDirectory = process.cwd()

/**
 * Returns the immutable facts for the current automation job run.
 */
export function context(): AutomationJobContext {
  return contextValue
}

/**
 * Appends one event to the automation job's owner session.
 */
export async function emitEvent(payload: unknown): Promise<void> {
  const encoded = JSON.stringify({ payload })
  if (encoded === undefined) throw new Error('emitEvent payload must be JSON-serializable')
  await requestBridge(encoded)
}

/** Upserts an external batch through this binding's current job attempt. */
export async function syncRecords(
  bindingID: string,
  records: { external_id: string; data: Record<string, unknown> }[],
  cursor?: Record<string, unknown>
): Promise<Record<string, unknown>> {
  const path = resolve(runDirectory, `.pod-sync-${randomUUID()}.json`)
  try {
    await writeFile(path, JSON.stringify(records), { flag: 'wx' })
    return await requestBridge(
      JSON.stringify({
        operation: 'pod.sync',
        binding_id: bindingID,
        records_path: path,
        ...(cursor === undefined ? {} : { cursor })
      })
    )
  } finally {
    await rm(path, { force: true })
  }
}

async function requestBridge(encoded: string): Promise<Record<string, unknown>> {
  const socketPath = process.env[emitSocketEnv]
  if (!socketPath) throw new Error('Automation SDK is available only inside an automation job run')

  return requestSocketLineBridge(socketPath, encoded, 'Automation job bridge returned an invalid response')
}

function readContext(): AutomationJobContext {
  const path = process.env[contextFileEnv]
  if (!path) throw new Error('context() is available only inside an automation job run')

  const value = JSON.parse(readFileSync(path, 'utf8')) as AutomationJobContext
  if (!value || typeof value !== 'object' || !value.event || !value.job) {
    throw new Error('automation job context file is invalid')
  }
  return Object.freeze({
    event: Object.freeze(value.event),
    job: Object.freeze(value.job)
  })
}

declare global {
  var context: () => AutomationJobContext
  var emitEvent: (payload: unknown) => Promise<void>
  var syncRecords: typeof import('./sdk').syncRecords
}

globalThis.context = context
globalThis.emitEvent = emitEvent
globalThis.syncRecords = syncRecords
