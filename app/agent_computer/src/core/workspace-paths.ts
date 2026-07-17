import { join, normalize, resolve } from 'node:path'
import { pathIsWithin, relativePathWithin, resolvePathWithin } from './path-boundary'

export const WORKSPACE_MODEL_ROOT = '/workspace'
export const WORKSPACE_SESSIONS_ROOT = `${WORKSPACE_MODEL_ROOT}/.sessions`
export const WORKSPACE_SHARED_ROOT = `${WORKSPACE_MODEL_ROOT}/shared`
export const WORKSPACE_USER_FILES_ROOT = `${WORKSPACE_SHARED_ROOT}/user-files`
export const WORKSPACE_AGENT_INSTALLED_SKILLS_ROOT = `${WORKSPACE_SHARED_ROOT}/skills/agents`
export const BUILTIN_SKILLS_ROOT = '/repo/app/library'
export const INTERNAL_SKILLS_ROOT = '/repo/internals/skills'

export type NonWorkspaceAbsolutePathMode = 'anchor' | 'reject'

export interface ResolveWorkspacePathOptions {
  /**
   * Model-facing or workspace-relative working directory for relative paths.
   * Defaults to the workspace root.
   */
  cwd?: string
  /**
   * Legacy computer tools anchor absolute non-/workspace paths inside
   * the session workspace. Stricter callers such as codex workdirs can reject
   * them explicitly.
   */
  nonWorkspaceAbsolute?: NonWorkspaceAbsolutePathMode
  errorMessage?: string
}

export interface SanitizePathSegmentOptions {
  fallback?: string
  replacement?: string
}

const safePathSegmentMaxLength = 96

/**
 * Resolves a model-facing path against the real session workspace root.
 */
export function resolveWorkspacePath(
  workspaceRoot: string,
  path: string,
  options: ResolveWorkspacePathOptions = {}
): string {
  const root = resolve(workspaceRoot)
  const errorMessage = options.errorMessage ?? 'path escapes workspace root'
  const mode = options.nonWorkspaceAbsolute ?? 'anchor'
  const base = options.cwd ? resolveWorkspacePath(workspaceRoot, options.cwd, { nonWorkspaceAbsolute: mode }) : root

  const resolved = isWorkspacePath(path)
    ? resolvePathWithin(root, `.${path.slice(WORKSPACE_MODEL_ROOT.length)}`, errorMessage)
    : path.startsWith('/')
      ? resolveNonWorkspaceAbsolute(root, path, mode, errorMessage)
      : resolve(base, normalize(path))

  if (!pathIsWithin(root, resolved)) {
    throw new Error(errorMessage)
  }

  return resolved
}

/**
 * Converts a real workspace path back to the model-facing /workspace path.
 */
export function toWorkspacePath(workspaceRoot: string, path: string): string {
  const root = resolve(workspaceRoot)
  const resolved = resolve(path)
  if (resolved === root) return WORKSPACE_MODEL_ROOT
  const relativePath = relativePathWithin(root, resolved)
  if (relativePath !== undefined) {
    return join(WORKSPACE_MODEL_ROOT, relativePath).replaceAll('\\', '/')
  }
  return path
}

/**
 * Checks whether a real path sits inside the session workspace root.
 */
export function insideWorkspace(workspaceRoot: string, path: string): boolean {
  return pathIsWithin(workspaceRoot, path)
}

export function toWorkspacePathStrict(workspaceRoot: string, path: string): string {
  const root = resolve(workspaceRoot)
  const resolved = resolve(path)
  const relativePath = relativePathWithin(root, resolved)
  if (relativePath === undefined) throw new Error('path escapes workspace root')
  return relativePath ? join(WORKSPACE_MODEL_ROOT, relativePath).replaceAll('\\', '/') : WORKSPACE_MODEL_ROOT
}

/**
 * Checks whether a path uses the model-facing /workspace virtual root.
 */
export function isWorkspacePath(path: string): boolean {
  return path === WORKSPACE_MODEL_ROOT || path.startsWith(`${WORKSPACE_MODEL_ROOT}/`)
}

/**
 * Sanitizes model/user supplied identifiers before embedding them in paths.
 */
export function sanitizePathSegment(value: string, options: SanitizePathSegmentOptions = {}): string {
  const replacement = options.replacement ?? '-'
  const fallback = options.fallback ?? 'default'
  const trimReplacement = replacement === '-'
  let safe = value.trim().replace(/[^a-zA-Z0-9._-]+/g, replacement)

  if (trimReplacement && replacement.length > 0) {
    const escaped = escapeRegExp(replacement)
    safe = safe.replace(new RegExp(`^${escaped}+|${escaped}+$`, 'g'), '')
  }

  safe = safe.slice(0, safePathSegmentMaxLength)
  return safe || fallback
}

function resolveNonWorkspaceAbsolute(
  root: string,
  path: string,
  mode: NonWorkspaceAbsolutePathMode,
  errorMessage: string
): string {
  if (mode === 'reject') throw new Error(errorMessage)
  return resolve(root, `.${normalize(path)}`)
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}
