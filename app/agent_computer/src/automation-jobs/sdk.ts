import { readFileSync } from 'node:fs'
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
}

globalThis.context = context
globalThis.emitEvent = emitEvent
