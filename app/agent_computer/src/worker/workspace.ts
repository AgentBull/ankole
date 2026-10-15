import { mkdirAgentSync } from '../common/agent-user'
import { join } from 'node:path'
import { agentHomePaths, sessionWorkspacePath } from '../core/agent-home-paths'
import type { WorkerConfig } from './config'

export function prepareTurnWorkspace(config: Pick<WorkerConfig, 'agentHomeRoot'>): string {
  const paths = prepareAgentHome(config.agentHomeRoot)
  return paths.jobs
}

export function prepareActorWorkspace(config: Pick<WorkerConfig, 'agentHomeRoot'>, workspaceID: number): string {
  prepareAgentHome(config.agentHomeRoot)
  const sessionRoot = sessionWorkspacePath(config.agentHomeRoot, workspaceID)
  mkdirAgentSync(sessionRoot)
  mkdirAgentSync(join(sessionRoot, 'temp'))

  return sessionRoot
}

/**
 * Creates missing directories of the Agent Home without cleaning existing
 * contents. Worker readiness creates the Agent Home itself at startup.
 */
function prepareAgentHome(agentHomeRoot: string) {
  const paths = agentHomePaths(agentHomeRoot)
  mkdirAgentSync(paths.codexHome, 0o700)
  mkdirAgentSync(paths.installedSkills)
  mkdirAgentSync(paths.sessions)
  mkdirAgentSync(paths.jobs)
  return paths
}
