import { existsSync, lstatSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { agentHomePaths, jobWorkspacePath } from '../agent-home-paths'

export type PreparedCodexJobProject = {
  root: string
  codexCwd: string
}

export function codexJobProjectLocation(
  agentsRoot: string,
  agentUID: string,
  workspaceOwnerJobID: string
): { hostPath: string; agentHome: string } {
  return {
    hostPath: jobWorkspacePath(agentsRoot, agentUID, workspaceOwnerJobID),
    agentHome: agentHomePaths(agentsRoot, agentUID).home
  }
}

export function assertCodexJobProjectResumeState(projectRoot: string): void {
  if (!existsSync(projectRoot)) {
    throw new Error('Background agent job workspace is missing for a persisted runtime thread')
  }
  const stat = lstatSync(projectRoot)
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    throw new Error('Background agent job workspace must be a real directory for a persisted runtime thread')
  }
}

export function prepareCodexJobProject(input: { jobProjectRoot: string }): PreparedCodexJobProject {
  ensureRealDirectory(input.jobProjectRoot, 'Background agent job workspace')
  ensureRealDirectory(join(input.jobProjectRoot, 'temp'), 'Background agent job temp directory')
  if (existsSync(join(input.jobProjectRoot, '.git'))) {
    throw new Error('Background agent job workspace must remain non-Git')
  }
  return { root: input.jobProjectRoot, codexCwd: input.jobProjectRoot }
}

function ensureRealDirectory(path: string, label: string): void {
  if (!existsSync(path)) {
    mkdirSync(path, { recursive: true })
    return
  }
  const stat = lstatSync(path)
  if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error(`${label} must be a real directory`)
}
