import { readFileSync } from 'node:fs'

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

  const socketPath = process.env[emitSocketEnv]
  if (!socketPath) throw new Error('emitEvent is available only inside an automation job run')

  await new Promise<void>((resolve, reject) => {
    let response = ''
    let settled = false

    void Bun.connect({
      unix: socketPath,
      socket: {
        open(socket) {
          socket.write(`${encoded}\n`)
        },
        data(_socket, data) {
          response += Buffer.from(data).toString('utf8')
        },
        close() {
          if (settled) return
          settled = true

          try {
            const result = JSON.parse(response.trim()) as { ok: boolean; error?: string }
            if (result.ok) resolve()
            else reject(new Error(result.error || 'emitEvent was rejected'))
          } catch {
            reject(new Error('emitEvent bridge returned an invalid response'))
          }
        },
        connectError(_socket, error) {
          if (settled) return
          settled = true
          reject(error)
        },
        error(_socket, error) {
          if (settled) return
          settled = true
          reject(error)
        }
      }
    }).catch(error => {
      if (settled) return
      settled = true
      reject(error)
    })
  })
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
