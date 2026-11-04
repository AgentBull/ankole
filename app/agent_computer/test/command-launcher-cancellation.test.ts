import { expect, test } from 'bun:test'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { isRootWorker, mkdirAgentSync } from '../src/common/agent-user'
import { killProcessGroup } from '../src/core/execution/process-group'
import type { DriveView } from '../src/drive/mounts'
import { runWorkspaceCommand } from '../src/tools/computer/commands'

// A root Worker adds a launcher before the Python command supervisor.
test.skipIf(!isRootWorker())(
  'cancellation reaches the command supervisor through a TERM-ignoring launcher',
  async () => {
    const home = mkdtempSync(join(tmpdir(), 'ankole-command-launcher-'))
    mkdirAgentSync(home)
    const ready = join(home, 'ready')
    const later = join(home, 'later')
    const launcherPid = join(home, 'launcher-pid')
    const launcher = join(home, 'launcher.py')
    writeFileSync(
      launcher,
      [
        'import os, signal, subprocess, sys',
        'signal.signal(signal.SIGTERM, signal.SIG_IGN)',
        `open(${JSON.stringify(launcherPid)}, 'w').write(str(os.getpid()))`,
        'sys.exit(subprocess.Popen(sys.argv[1:]).wait())'
      ].join('\n')
    )
    const view = {
      scope: { path: '/unused/scope' },
      library: { path: '/unused/library' },
      recovery: '/unused/recovery',
      sequence: async () => new Map(),
      flush: async () => '',
      launcher: (argv: string[]) => ['python3', launcher, ...argv]
    } as unknown as DriveView
    const abort = new AbortController()
    let settled = false
    const running = runWorkspaceCommand(
      {
        cmd: 'bash',
        args: ['-c', `trap '' TERM; printf '%s' "$$" > '${ready}'; (sleep 1; printf leaked > '${later}') & wait`],
        signal: abort.signal,
        driveView: view,
        timeoutMs: 5_000
      },
      home,
      home
    ).finally(() => {
      settled = true
    })
    try {
      const readyDeadline = Date.now() + 3_000
      while (!existsSync(ready) && Date.now() < readyDeadline) await Bun.sleep(10)
      expect(existsSync(ready)).toBe(true)
      abort.abort()
      const stopDeadline = Date.now() + 500
      while (!settled && Date.now() < stopDeadline) await Bun.sleep(10)
      expect(settled).toBe(true)
      expect((await running).exitCode).toBe(130)
      await Bun.sleep(1_100)
      expect(existsSync(later)).toBe(false)
    } finally {
      if (!settled) {
        for (const path of [ready, launcherPid]) {
          if (existsSync(path)) {
            killProcessGroup(Number(readFileSync(path, 'utf8')))
          }
        }
      }
      await running
      rmSync(home, { recursive: true, force: true })
    }
  },
  10_000
)
