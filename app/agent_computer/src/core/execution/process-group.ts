import { AGENT_GID, AGENT_UID, isRootWorker } from '../../common/agent-user'
import type { DriveView } from '../../drive/mounts'

/** Callers start the process with `detached: true`, so this PID leads the group. */
export function killProcessGroup(pid: number | undefined, signal: NodeJS.Signals = 'SIGKILL'): void {
  if (!pid) return

  try {
    process.kill(-pid, signal)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error
  }
}
/** All model-driven processes drop the Worker's identity before execution. */
export function agentProcessArgv(argv: string[], drive?: DriveView, cwd?: string): string[] {
  if (!isRootWorker()) return argv
  const command = [
    '/usr/bin/setpriv',
    `--reuid=${AGENT_UID}`,
    `--regid=${AGENT_GID}`,
    '--clear-groups',
    '--inh-caps=-all',
    '--ambient-caps=-all',
    '--bounding-set=-all',
    '--no-new-privs',
    '--',
    ...(drive && cwd ? ['/bin/sh', '-c', 'cd -- "$1" || exit; shift; exec "$@"', 'drive-command', cwd, ...argv] : argv)
  ]
  return drive ? drive.launcher(command) : command
}
