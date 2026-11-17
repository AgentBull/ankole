import { existsSync, lstatSync, utimesSync } from 'node:fs'
import { mkdirAgentSync } from '../../../common/agent-user'
import { join } from 'node:path'
import { agentHomePaths, jobWorkspacePath } from '../../agent-home-paths'

/** The Job Workspace root is the real process directory and the Codex project root. */
export type PreparedCodexJobProject = {
  root: string
}

export function codexJobProjectLocation(
  agentHomeRoot: string,
  workspaceOwnerJobID: string
): { hostPath: string; agentHome: string } {
  return {
    hostPath: jobWorkspacePath(agentHomeRoot, workspaceOwnerJobID),
    agentHome: agentHomePaths(agentHomeRoot).home
  }
}

export function checkCodexJobProjectResumeState(projectRoot: string): { workspaceMissing: boolean } {
  let stat: ReturnType<typeof lstatSync>
  try {
    stat = lstatSync(projectRoot)
  } catch (error) {
    if ((error as NodeJS.ErrnoException)?.code === 'ENOENT') {
      return { workspaceMissing: true }
    }
    throw error
  }
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    throw new Error('Background agent job workspace must be a real directory for a persisted runtime thread')
  }
  return { workspaceMissing: false }
}

export function prepareCodexJobProject(input: { jobProjectRoot: string }): PreparedCodexJobProject {
  ensureRealDirectory(input.jobProjectRoot, 'Background agent job workspace')
  ensureRealDirectory(join(input.jobProjectRoot, 'temp'), 'Background agent job temp directory')
  if (existsSync(join(input.jobProjectRoot, '.git'))) {
    throw new Error('Background agent job workspace must remain non-Git')
  }
  try {
    const now = new Date()
    utimesSync(input.jobProjectRoot, now, now)
  } catch {
    // Ignore filesystems that disallow utimes on non-owned mounts.
  }
  return { root: input.jobProjectRoot }
}

function ensureRealDirectory(path: string, label: string): void {
  let stat: ReturnType<typeof lstatSync> | undefined
  try {
    stat = lstatSync(path)
  } catch (error) {
    if ((error as NodeJS.ErrnoException)?.code !== 'ENOENT') throw error
  }
  if (!stat) {
    mkdirAgentSync(path)
    return
  }
  if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error(`${label} must be a real directory`)
}
