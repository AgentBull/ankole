import { normalize, relative, resolve, join } from 'node:path'

export const WORKSPACE_MODEL_ROOT = '/workspace'

export type NonWorkspaceAbsolutePathMode = 'anchor' | 'reject'

export interface ResolveWorkspacePathOptions {
  /**
   * Model-facing or workspace-relative working directory for relative paths.
   * Defaults to the workspace root.
   */
  cwd?: string
  /**
   * Legacy computer/browser tools anchor absolute non-/workspace paths inside
   * the session workspace. Stricter callers such as codex workdirs can reject
   * them explicitly.
   */
  nonWorkspaceAbsolute?: NonWorkspaceAbsolutePathMode
  errorMessage?: string
}

export interface SanitizePathSegmentOptions {
  fallback?: string
  maxLength?: number
  replacement?: string
  trimReplacement?: boolean
}

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
    ? resolve(root, `.${path.slice(WORKSPACE_MODEL_ROOT.length)}`)
    : path.startsWith('/')
      ? resolveNonWorkspaceAbsolute(root, path, mode, errorMessage)
      : resolve(base, normalize(path))

  if (!insideResolvedWorkspace(root, resolved)) {
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
  if (insideResolvedWorkspace(root, resolved)) {
    return join(WORKSPACE_MODEL_ROOT, relative(root, resolved)).replaceAll('\\', '/')
  }
  return path
}

/**
 * Checks whether a real path sits inside the session workspace root.
 */
export function insideWorkspace(workspaceRoot: string, path: string): boolean {
  return insideResolvedWorkspace(resolve(workspaceRoot), resolve(path))
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
  const maxLength = options.maxLength ?? 96
  const trimReplacement = options.trimReplacement ?? replacement === '-'
  let safe = value.trim().replace(/[^a-zA-Z0-9._-]+/g, replacement)

  if (trimReplacement && replacement.length > 0) {
    const escaped = escapeRegExp(replacement)
    safe = safe.replace(new RegExp(`^${escaped}+|${escaped}+$`, 'g'), '')
  }

  if (maxLength > 0) safe = safe.slice(0, maxLength)
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

function insideResolvedWorkspace(root: string, path: string): boolean {
  return path === root || path.startsWith(`${root}/`)
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}
