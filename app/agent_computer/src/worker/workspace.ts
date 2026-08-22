import { existsSync, mkdirSync, renameSync } from 'node:fs'
import { join } from 'node:path'
import type { TurnStart } from '../lanes/actor_lane'
import { agentHomePaths, sessionWorkspacePath } from '../core/agent-home-paths'
import type { WorkerConfig } from './config'

/**
 * Creates the direct Session Workspace inside the current Agent Home.
 *
 * `user-files` remains a sibling shared across the Agent's Sessions; no path
 * alias or symlink is needed because the model sees the real Agent Home paths.
 */
export function prepareTurnWorkspace(config: WorkerConfig, turnStart: TurnStart): string {
  return prepareActorWorkspace(config, turnStart.turn.actor, turnStart.workspace_id)
}

/** Prepares the Agent Home, migrates the legacy path, and returns the Workspace. */
export function prepareActorWorkspace(
  config: Pick<WorkerConfig, 'agentsRoot'>,
  actor: { agent_uid: string; session_id: string },
  workspaceID: number
): string {
  prepareAgentHome(config.agentsRoot, actor.agent_uid)
  const sessionRoot = sessionWorkspacePath(config.agentsRoot, actor.agent_uid, workspaceID)
  migrateLegacySessionWorkspace(config.agentsRoot, actor, sessionRoot)

  mkdirSync(sessionRoot, { recursive: true })
  mkdirSync(join(sessionRoot, 'temp'), { recursive: true })

  return sessionRoot
}

/**
 * Moves the former Base64URL directory on first access.
 *
 * Remove this migration after every retained Agent Home has completed one
 * post-v4 turn or has been checked for legacy session directories.
 */
function migrateLegacySessionWorkspace(
  agentsRoot: string,
  actor: { agent_uid: string; session_id: string },
  sessionRoot: string
): void {
  if (!actor.session_id) throw new Error('Session ID is required to migrate its legacy workspace')
  const legacyKey = Buffer.from(actor.session_id, 'utf8').toString('base64url')
  const legacyRoot = join(agentHomePaths(agentsRoot, actor.agent_uid).sessions, legacyKey)
  if (legacyRoot === sessionRoot) return

  if (existsSync(sessionRoot) && existsSync(legacyRoot)) {
    throw new Error(`Session workspace migration conflict: both ${legacyRoot} and ${sessionRoot} exist`)
  }

  if (!existsSync(sessionRoot) && existsSync(legacyRoot)) {
    try {
      renameSync(legacyRoot, sessionRoot)
    } catch (error) {
      if (!existsSync(sessionRoot) || existsSync(legacyRoot)) throw error
    }
  }

  if (existsSync(sessionRoot) && existsSync(legacyRoot)) {
    throw new Error(`Session workspace migration conflict: both ${legacyRoot} and ${sessionRoot} exist`)
  }
}

/** Creates missing Agent Home directories without cleaning existing contents. */
export function prepareAgentHome(agentsRoot: string, agentUID: string) {
  const paths = agentHomePaths(agentsRoot, agentUID)
  mkdirSync(paths.home, { recursive: true, mode: 0o700 })
  mkdirSync(paths.codexHome, { recursive: true, mode: 0o700 })
  mkdirSync(paths.userFiles, { recursive: true })
  mkdirSync(paths.installedSkills, { recursive: true })
  mkdirSync(paths.sessions, { recursive: true })
  mkdirSync(paths.jobs, { recursive: true })
  return paths
}
