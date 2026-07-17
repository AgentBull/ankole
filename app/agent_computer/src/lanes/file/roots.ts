import { resolve } from 'node:path'
import type { WorkerConfig } from '../../worker/config'

const fileRootResolvers = {
  user_files: (config: WorkerConfig) => config.userFilesRoot,
  agent_installed_skills: (config: WorkerConfig) => config.agentInstalledSkillsRoot,
  workspace_sessions: (config: WorkerConfig) => config.workspaceSessionsRoot,
  codex_accounts: (config: WorkerConfig) => resolve(config.sharedFsRoot, '.ankole', 'codex'),
  background_agent_jobs: (config: WorkerConfig) => resolve(config.sharedFsRoot, '.ankole', 'background-agent-jobs')
} as const

export type FileRoot = keyof typeof fileRootResolvers

export function isFileRoot(value: string): value is FileRoot {
  return Object.hasOwn(fileRootResolvers, value)
}

export function rootPathFor(config: WorkerConfig, root: FileRoot): string {
  return fileRootResolvers[root](config)
}
