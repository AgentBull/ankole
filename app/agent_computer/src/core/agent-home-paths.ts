import { join, normalize, resolve } from 'node:path'
import { pathIsWithin } from './path-boundary'
import { modelIntegerIDFromWire } from './model-integer-id'

export const AGENTS_ROOT = '/agents'
export const WORKER_SHARE_ROOT = '/var/share'
export const BUILTIN_SKILLS_ROOT = '/repo/app/library'
export const INTERNAL_SKILLS_ROOT = '/repo/internals/skills'
export const AGENT_UID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,95}$/

export type AgentHomePaths = {
  agentKey: string
  home: string
  codexHome: string
  soul: string
  mission: string
  design: string
  userFiles: string
  installedSkills: string
  sessions: string
  jobs: string
}

export function assertAgentKey(value: string): string {
  if (!AGENT_UID_PATTERN.test(value)) {
    throw new Error('Agent UID must match ^[a-z0-9][a-z0-9._-]{0,95}$ before it can own files')
  }
  return value
}

export function agentHomePaths(agentsRoot: string, agentUID: string): AgentHomePaths {
  const agentKey = assertAgentKey(agentUID)
  const home = join(resolve(agentsRoot), agentKey)
  return {
    agentKey,
    home,
    codexHome: join(home, '.codex'),
    soul: join(home, 'SOUL.md'),
    mission: join(home, 'MISSION.md'),
    design: join(home, 'DESIGN.md'),
    userFiles: join(home, 'user-files'),
    installedSkills: join(home, 'installed-skills'),
    sessions: join(home, 'sessions'),
    jobs: join(home, 'jobs')
  }
}

export function encodeSessionKey(sessionID: string): string {
  if (!sessionID) throw new Error('Session ID is required before it can own a workspace')
  return Buffer.from(sessionID, 'utf8').toString('base64url')
}

export function sessionWorkspacePath(agentsRoot: string, agentUID: string, sessionID: string): string {
  return join(agentHomePaths(agentsRoot, agentUID).sessions, encodeSessionKey(sessionID))
}

export function jobWorkspacePath(agentsRoot: string, agentUID: string, jobID: string): string {
  modelIntegerIDFromWire(jobID, 'background Agent Job id')
  return join(agentHomePaths(agentsRoot, agentUID).jobs, jobID)
}

export function resolveAgentHomePath(
  agentHome: string,
  path: string,
  options: { cwd?: string; errorMessage?: string } = {}
): string {
  const home = resolve(agentHome)
  const errorMessage = options.errorMessage ?? 'path escapes Agent Home'
  const cwd = resolve(options.cwd ?? home)
  if (!pathIsWithin(home, cwd)) throw new Error(errorMessage)

  const expanded = path === '~' ? home : path.startsWith('~/') ? join(home, path.slice(2)) : path
  const resolved = expanded.startsWith('/') ? resolve(normalize(expanded)) : resolve(cwd, normalize(expanded))
  if (!pathIsWithin(home, resolved)) throw new Error(errorMessage)
  return resolved
}

export function insideAgentHome(agentHome: string, path: string): boolean {
  return pathIsWithin(resolve(agentHome), resolve(path))
}

export function assertPathInsideAgentHome(
  agentHome: string,
  path: string,
  message = 'path escapes Agent Home'
): string {
  const resolved = resolve(path)
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
