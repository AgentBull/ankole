import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { modelIntegerIDFromWire } from './model-integer-id'

export const AGENT_HOME = '/workspace'
export const WORKER_SHARE_ROOT = process.env.TMPDIR ? tmpdir() : '/var/share'

/** SQLite and its process lock require the local cache filesystem. */
export function codexSQLiteHome(): string {
  // The Worker image sets this variable, and the entry restores it.
  return process.env.CODEX_SQLITE_HOME!
}

export type AgentHomePaths = {
  home: string
  codexHome: string
  agents: string
  design: string
  sessions: string
  jobs: string
}

export function agentHomePaths(agentHomeRoot: string): AgentHomePaths {
  const home = resolve(agentHomeRoot)
  return {
    home,
    codexHome: join(home, '.codex'),
    agents: join(home, 'AGENTS.md'),
    design: join(home, 'DESIGN.md'),
    sessions: join(home, 'sessions'),
    jobs: join(home, 'jobs')
  }
}

export function sessionWorkspacePath(agentHomeRoot: string, workspaceID: number): string {
  if (!Number.isSafeInteger(workspaceID) || workspaceID < 10_000) {
    throw new Error('Session workspace ID must be a model-safe integer starting at 10000')
  }
  return join(agentHomePaths(agentHomeRoot).sessions, String(workspaceID))
}

export function jobWorkspacePath(agentHomeRoot: string, jobID: string): string {
  modelIntegerIDFromWire(jobID, 'background Agent Job id')
  return join(agentHomePaths(agentHomeRoot).jobs, jobID)
}

export interface SanitizePathSegmentOptions {
  fallback?: string
  replacement?: string
}

const safePathSegmentMaxLength = 96

export function sanitizePathSegment(value: string, options: SanitizePathSegmentOptions = {}): string {
  const replacement = options.replacement ?? '-'
  const fallback = options.fallback ?? 'default'
  const trimReplacement = replacement === '-'
  let safe = value.trim().replace(/[^a-zA-Z0-9._-]+/g, replacement)

  if (trimReplacement && replacement.length > 0) {
    safe = safe.replace(/^-+|-+$/g, '')
  }

  safe = safe.slice(0, safePathSegmentMaxLength)
  return safe || fallback
}
