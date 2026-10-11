import { AGENT_GID, AGENT_UID, isRootWorker } from '../../common/agent-user'

/**
 * Ends a process that was started with `detached: true`, together with every
 * process that it started. Such a process leads its own process group, so the
 * negative PID reaches the whole group. A group that has already exited is not
 * an error.
 */
export function killProcessGroup(pid: number | undefined, signal: NodeJS.Signals = 'SIGKILL'): void {
  if (!pid) return

  try {
    process.kill(-pid, signal)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error
  }
}
/** All model-driven processes drop the Worker's identity before execution. */
export function agentProcessArgv(argv: string[]): string[] {
  if (!isRootWorker()) return argv
  return [
    '/usr/bin/setpriv',
    `--reuid=${AGENT_UID}`,
    `--regid=${AGENT_GID}`,
    '--clear-groups',
    '--inh-caps=-all',
    '--ambient-caps=-all',
    '--no-new-privs',
    '--',
    ...argv
  ]
}
