import { jsonObject } from '@agentbull/active-support'
import { stringValue } from '../protocol'
import type { JSONRPCMessage } from './app-server-client'

/** Log bound for unscoped app-server stderr diagnostics. */
const MAX_RUNTIME_STDERR_DIAGNOSTIC_LENGTH = 2_048

export function runtimeStderrDiagnostic(message: JSONRPCMessage): string | undefined {
  if (message.method !== '$stderr') return undefined
  const text = stringValue(jsonObject(message.params).text)?.trim()
  if (!text) return undefined

  return text
    .replace(/(authorization\s*[:=]\s*)(?:(?:bearer|basic)\s+)?\S+/gi, '$1[REDACTED]')
    .replace(/((?:api[_-]?key|token|secret|password)\s*[:=]\s*)\S+/gi, '$1[REDACTED]')
    .replace(/\b(?:bx_mcp|sk)[_-][A-Za-z0-9_-]+\b/g, '[REDACTED]')
    .replace(/\b[A-Za-z0-9_-]{48,}\b/g, '[REDACTED]')
    .replace(/\s+/g, ' ')
    .slice(0, MAX_RUNTIME_STDERR_DIAGNOSTIC_LENGTH)
}

export function childThreadLink(
  message: JSONRPCMessage,
  eventThreadID: string | undefined,
  thread: Record<string, unknown>
): { parentThreadID: string; childThreadID: string } | undefined {
  if (message.method === 'thread/started') {
    const parentThreadID = stringValue(thread.parentThreadId)
    const childThreadID = stringValue(thread.id)
    return parentThreadID && childThreadID ? { parentThreadID, childThreadID } : undefined
  }

  if ((message.method !== 'item/started' && message.method !== 'item/completed') || !eventThreadID) return undefined
  const item = jsonObject(jsonObject(message.params).item)
  if (item.type !== 'subAgentActivity' || item.kind !== 'started') return undefined
  const childThreadID = stringValue(item.agentThreadId)
  return childThreadID ? { parentThreadID: eventThreadID, childThreadID } : undefined
}

export function waitWithAbort<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
  signal?.throwIfAborted()
  if (!signal) return promise
  return new Promise<T>((resolve, reject) => {
    const onAbort = (): void => reject(signal.reason ?? new DOMException('Runtime acquire was aborted', 'AbortError'))
    signal.addEventListener('abort', onAbort, { once: true })
    void promise.then(
      value => {
        signal.removeEventListener('abort', onAbort)
        resolve(value)
      },
      error => {
        signal.removeEventListener('abort', onAbort)
        reject(error)
      }
    )
  })
}

export function withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(message)), timeoutMs)
    timeout.unref?.()
    void promise.then(
      value => {
        clearTimeout(timeout)
        resolve(value)
      },
      error => {
        clearTimeout(timeout)
        reject(error)
      }
    )
  })
}
