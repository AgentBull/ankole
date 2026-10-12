import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { pathIsWithin } from './path-boundary'
import { canonicalPath } from './real-path-boundary'
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
  soul: string
  mission: string
  design: string
  confidentialityPolicy: string
  installedSkills: string
  sessions: string
  jobs: string
}

export function agentHomePaths(agentHomeRoot: string): AgentHomePaths {
  const home = resolve(agentHomeRoot)
  return {
    home,
    codexHome: join(home, '.codex'),
    soul: join(home, 'SOUL.md'),
    mission: join(home, 'MISSION.md'),
    design: join(home, 'DESIGN.md'),
    confidentialityPolicy: join(home, 'ConfidentialityPolicy.md'),
    installedSkills: join(home, 'installed-skills'),
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

export function insideAgentHome(agentHome: string, path: string): boolean {
  return pathIsWithin(canonicalPath(agentHome), canonicalPath(path))
}

export function assertPathInsideAgentHome(
  agentHome: string,
  path: string,
  message = 'path escapes Agent Home'
): string {
  const resolved = canonicalPath(path)
  if (!insideAgentHome(agentHome, resolved)) throw new Error(message)
  return resolved
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
    const escaped = replacement.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    safe = safe.replace(new RegExp(`^${escaped}+|${escaped}+$`, 'g'), '')
  }

  safe = safe.slice(0, safePathSegmentMaxLength)
  return safe || fallback
}
