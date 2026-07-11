import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { safePath, sanitizeID } from './utils'
import type { BrowserRef, BrowserRuntimeOptions, BrowserSessionMeta } from './types'

/**
 * Reads persisted metadata for a browser session.
 */
export function readSessionMeta(session: string, options?: BrowserRuntimeOptions): BrowserSessionMeta | undefined {
  const path = sessionPath(session, options)
  if (!existsSync(path)) return undefined
  return JSON.parse(readFileSync(path, 'utf8')) as BrowserSessionMeta
}

/**
 * Writes persisted metadata for a browser session.
 */
export function writeSessionMeta(session: string, meta: BrowserSessionMeta, options?: BrowserRuntimeOptions): void {
  const path = sessionPath(session, options)
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, JSON.stringify(meta, null, 2))
}

/**
 * Returns the metadata path for a browser session.
 */
function sessionPath(session: string, options?: BrowserRuntimeOptions): string {
  return resolve(browserRoot(session, options), 'session.json')
}

/**
 * Reads the latest snapshot refs for a browser session.
 */
export function readRefs(session: string, options?: BrowserRuntimeOptions): BrowserRef[] {
  const path = resolve(browserRoot(session, options), 'refs.json')
  if (!existsSync(path)) return []
  const payload = JSON.parse(readFileSync(path, 'utf8')) as { elements?: BrowserRef[] }
  return payload.elements ?? []
}

/**
 * Writes the latest snapshot refs for a browser session.
 */
export function writeRefs(session: string, elements: BrowserRef[], options?: BrowserRuntimeOptions): void {
  const path = resolve(browserRoot(session, options), 'refs.json')
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, JSON.stringify({ elements, updated_at_unix_ms: Date.now() }, null, 2))
}

/**
 * Returns the browser state directory for a session.
 */
export function browserRoot(session: string, options?: BrowserRuntimeOptions): string {
  return safePath(`/workspace/.sessions/${sanitizeID(session)}/browser`, options)
}
