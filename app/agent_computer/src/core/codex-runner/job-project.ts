import { existsSync, lstatSync, mkdirSync, readdirSync, realpathSync } from 'node:fs'
import { dirname, join } from 'node:path'
import {
  insideWorkspace,
  resolveWorkspacePath,
  sanitizePathSegment,
  toWorkspacePath,
  WORKSPACE_MODEL_ROOT
} from '../workspace-paths'

export type CodexJobWorkspaceMountAccess = 'read_only' | 'read_write'

export type CodexJobWorkspaceMountInput = {
  id: string
  source: string
  access: CodexJobWorkspaceMountAccess
}

export type CodexJobWorkspaceMount = {
  id: string
  sourcePath: string
  projectPath: string
  modelPath: string
  ownerModelPath: string
  access: CodexJobWorkspaceMountAccess
}

export type PreparedCodexJobProject = {
  root: string
  ownerModelPath: string
  codexCwd: typeof WORKSPACE_MODEL_ROOT
  workspaceMounts: CodexJobWorkspaceMount[]
}

export function codexJobProjectLocation(
  userFilesRoot: string,
  jobID: string
): {
  hostPath: string
  ownerModelPath: string
} {
  if (!jobID || sanitizePathSegment(jobID, { replacement: '_' }) !== jobID) {
    throw new Error('Background agent job id is not a safe path segment')
  }
  const relativePath = `background-agent-jobs/${jobID}/project`
  return {
    hostPath: join(userFilesRoot, relativePath),
    ownerModelPath: `/workspace/user-files/${relativePath}`
  }
}

/**
 * Prepares the private non-Git project used as the fixed Codex cwd for one Job.
 * Target workspaces remain owner-session resources and are exposed only through
 * stable `workspaces/<mount-id>` bind mounts inside the sandbox.
 */
export function prepareCodexJobProject(input: {
  jobProjectRoot: string
  ownerModelPath: string
  ownerWorkspaceRoot: string
  allowedSourceRoots?: string[]
  workspaceMounts: CodexJobWorkspaceMountInput[]
}): PreparedCodexJobProject {
  ensureDirectoryWithoutSymlink(input.jobProjectRoot, 'Background agent job project root')
  if (existsSync(join(input.jobProjectRoot, '.git'))) {
    throw new Error('Background agent job project root must remain non-Git')
  }

  const realJobProjectRoot = realpathSync(input.jobProjectRoot)
  const realAllowedSourceRoots = [input.ownerWorkspaceRoot, ...(input.allowedSourceRoots ?? [])]
    .map(root => realpathSync(root))
    .filter((root, index, roots) => roots.indexOf(root) === index)
  const seenIDs = new Set<string>()
  const seenSources = new Set<string>()
  const workspacesRoot = join(input.jobProjectRoot, 'workspaces')
  ensureDirectoryWithoutSymlink(workspacesRoot, 'Background agent job workspaces root')

  const workspaceMounts = [...input.workspaceMounts]
    .sort((left, right) => compareCodePoints(left.id, right.id))
    .map(mount => {
      assertMountID(mount.id)
      if (seenIDs.has(mount.id)) {
        throw new Error(`Background agent job workspace mount id is duplicated: ${mount.id}`)
      }
      seenIDs.add(mount.id)

      const lexicalSourcePath = resolveWorkspacePath(input.ownerWorkspaceRoot, mount.source, {
        nonWorkspaceAbsolute: 'reject',
        errorMessage: `Background agent job workspace mount ${mount.id} must stay inside the owner workspace`
      })
      if (!existsSync(lexicalSourcePath) && mount.access === 'read_write') {
        const realAncestor = realpathSync(nearestExistingAncestor(dirname(lexicalSourcePath)))
        if (!insideAnyWorkspace(realAllowedSourceRoots, realAncestor)) {
          throw new Error(`Background agent job workspace mount ${mount.id} resolves outside the owner workspace`)
        }
        mkdirSync(lexicalSourcePath, { recursive: true })
      }
      if (!existsSync(lexicalSourcePath)) {
        throw new Error(`Background agent job read-only workspace mount does not exist: ${mount.id}`)
      }
      const sourcePath = realpathSync(lexicalSourcePath)
      if (!insideAnyWorkspace(realAllowedSourceRoots, sourcePath)) {
        throw new Error(`Background agent job workspace mount ${mount.id} resolves outside the owner workspace`)
      }
      if (insideWorkspace(realJobProjectRoot, sourcePath) || insideWorkspace(sourcePath, realJobProjectRoot)) {
        throw new Error('Background agent job workspace mount must not overlap its private project root')
      }
      if (seenSources.has(sourcePath)) {
        throw new Error(`Background agent job workspace source is mounted more than once: ${mount.source}`)
      }
      seenSources.add(sourcePath)

      const projectPath = join(workspacesRoot, mount.id)
      ensureDirectoryWithoutSymlink(projectPath, `Background agent job workspace mountpoint ${mount.id}`)
      if (readdirSync(projectPath).length > 0) {
        throw new Error(`Background agent job workspace mountpoint must stay empty outside the sandbox: ${mount.id}`)
      }

      return {
        id: mount.id,
        sourcePath,
        projectPath,
        modelPath: `${WORKSPACE_MODEL_ROOT}/workspaces/${mount.id}`,
        ownerModelPath: toWorkspacePath(input.ownerWorkspaceRoot, lexicalSourcePath),
        access: mount.access
      }
    })

  return {
    root: input.jobProjectRoot,
    ownerModelPath: input.ownerModelPath,
    codexCwd: WORKSPACE_MODEL_ROOT,
    workspaceMounts
  }
}

function insideAnyWorkspace(roots: string[], path: string): boolean {
  return roots.some(root => insideWorkspace(root, path))
}

function nearestExistingAncestor(path: string): string {
  let candidate = path
  while (!existsSync(candidate)) {
    const parent = dirname(candidate)
    if (parent === candidate) throw new Error('Background agent job workspace source has no existing ancestor')
    candidate = parent
  }
  return candidate
}

function ensureDirectoryWithoutSymlink(path: string, label: string): void {
  if (!existsSync(path)) {
    mkdirSync(path, { recursive: true })
    return
  }
  const stat = lstatSync(path)
  if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error(`${label} must be a real directory`)
}

function compareCodePoints(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}

function assertMountID(id: string): void {
  if (!id || id === '.' || id === '..' || sanitizePathSegment(id, { replacement: '_' }) !== id) {
    throw new Error(`Background agent job workspace mount id is not a safe path segment: ${id || '<empty>'}`)
  }
}
