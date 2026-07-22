export const WORKER_FILE_ROOTS = ['agent_sessions', 'user_files', 'agent_installed_skills'] as const

export type WorkerFileRoot = (typeof WORKER_FILE_ROOTS)[number]

const ROOT_DIRECTORIES: Record<WorkerFileRoot, string> = {
  agent_sessions: 'sessions',
  user_files: 'user-files',
  agent_installed_skills: 'installed-skills'
}

export function workerFileRootPath(root: WorkerFileRoot, agentUID: string): string {
  return `${agentUID}/${ROOT_DIRECTORIES[root]}`
}

export function agentUIDFromWorkerFilePath(root: WorkerFileRoot, path: string): string | undefined {
  const [agentUID, directory] = path.split('/')
  if (!agentUID || !/^[a-z0-9][a-z0-9._-]{0,95}$/.test(agentUID) || directory !== ROOT_DIRECTORIES[root]) {
    return undefined
  }
  return agentUID
}
