import { afterEach, describe, expect, it } from 'bun:test'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  CODEX_HOME_LOCK_BUSY_EXIT_CODE,
  CODEX_LOGS2_DATABASE_NAMES,
  codexHomeLockedCommandArgv,
  codexHomeLockedLogsDeleteArgv
} from '../src/core/codex-runner/codex-home-lock'
import { retireLegacySharedCodexConfig } from '../src/core/codex-runner/retire-legacy-shared-codex-config'

const previousFlockBinary = process.env.ANKOLE_FLOCK_BINARY

afterEach(() => {
  if (previousFlockBinary === undefined) delete process.env.ANKOLE_FLOCK_BINARY
  else process.env.ANKOLE_FLOCK_BINARY = previousFlockBinary
})

describe('@ankole/agent-computer Codex Home physical lock', () => {
  it('excludes a second process and serializes cold and daily logs_2 deletion', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-home-lock-'))
    const codexHome = join(root, 'codex-home')
    const ready = join(root, 'ready')
    const release = join(root, 'release')
    const lockHelper = join(root, 'flock')
    const databasePaths = CODEX_LOGS2_DATABASE_NAMES.map(name => join(codexHome, name))
    const unrelated = join(codexHome, 'logs_2.sqlite.backup')
    let runtime: ReturnType<typeof Bun.spawn> | undefined

    try {
      writePortableFlock(lockHelper)
      process.env.ANKOLE_FLOCK_BINARY = lockHelper
      mkdirSync(codexHome)
      writeFileSync(unrelated, 'keep')
      for (const path of databasePaths) writeFileSync(path, 'cold')

      runtime = Bun.spawn(
        codexHomeLockedCommandArgv({
          codexHome,
          deleteLogsBeforeCommand: true,
          commandArgv: [
            '/bin/sh',
            '-c',
            'touch "$1"; while [ ! -e "$2" ]; do sleep 0.02; done',
            'ankole-test-runtime',
            ready,
            release
          ]
        }),
        { stdout: 'pipe', stderr: 'pipe' }
      )
      await waitForFile(ready)
      expect(databasePaths.every(path => !existsSync(path))).toBe(true)
      expect(existsSync(unrelated)).toBe(true)

      for (const path of databasePaths) writeFileSync(path, 'active')
      const contender = Bun.spawn(codexHomeLockedCommandArgv({ codexHome, commandArgv: ['/bin/true'] }))
      expect(await contender.exited).toBe(CODEX_HOME_LOCK_BUSY_EXIT_CODE)

      const activeReset = Bun.spawn(codexHomeLockedLogsDeleteArgv(codexHome))
      expect(await activeReset.exited).toBe(CODEX_HOME_LOCK_BUSY_EXIT_CODE)
      expect(databasePaths.every(existsSync)).toBe(true)

      writeFileSync(release, 'release')
      expect(await runtime.exited).toBe(0)
      runtime = undefined

      const stoppedReset = Bun.spawn(codexHomeLockedLogsDeleteArgv(codexHome), {
        stdout: 'pipe',
        stderr: 'pipe'
      })
      const [exitCode, stdout] = await Promise.all([stoppedReset.exited, new Response(stoppedReset.stdout).text()])
      expect(exitCode).toBe(0)
      expect(stdout.trim().split('\n').sort()).toEqual([...CODEX_LOGS2_DATABASE_NAMES].sort())
      expect(databasePaths.every(path => !existsSync(path))).toBe(true)
      expect(existsSync(unrelated)).toBe(true)
    } finally {
      runtime?.kill()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('retires only an unlocked legacy shared config and retries after an old runtime exits', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-legacy-codex-config-'))
    const agentHome = join(root, 'agent-home')
    const legacyCodexHome = join(agentHome, '.codex')
    const configPath = join(legacyCodexHome, 'config.toml')
    const retainedState = join(legacyCodexHome, 'state_5.sqlite')
    const ready = join(root, 'ready')
    const release = join(root, 'release')
    const lockHelper = join(root, 'flock')
    let oldRuntime: ReturnType<typeof Bun.spawn> | undefined

    try {
      writePortableFlock(lockHelper)
      process.env.ANKOLE_FLOCK_BINARY = lockHelper
      mkdirSync(legacyCodexHome, { recursive: true })
      writeFileSync(configPath, 'legacy config')
      writeFileSync(retainedState, 'keep')

      oldRuntime = Bun.spawn(
        codexHomeLockedCommandArgv({
          codexHome: legacyCodexHome,
          commandArgv: [
            '/bin/sh',
            '-c',
            'touch "$1"; while [ ! -e "$2" ]; do sleep 0.02; done',
            'ankole-old-runtime',
            ready,
            release
          ]
        })
      )
      await waitForFile(ready)

      await expect(retireLegacySharedCodexConfig(agentHome)).resolves.toBe('skipped_legacy_runtime_active')
      expect(existsSync(configPath)).toBe(true)
      expect(existsSync(retainedState)).toBe(true)

      writeFileSync(release, 'release')
      expect(await oldRuntime.exited).toBe(0)
      oldRuntime = undefined

      await expect(retireLegacySharedCodexConfig(agentHome)).resolves.toBe('removed')
      expect(existsSync(configPath)).toBe(false)
      expect(existsSync(retainedState)).toBe(true)
      await expect(retireLegacySharedCodexConfig(agentHome)).resolves.toBe('config_missing')
    } finally {
      oldRuntime?.kill()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('does not follow a legacy Codex Home symlink', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-legacy-codex-symlink-'))
    const agentHome = join(root, 'agent-home')
    const outsideCodexHome = join(root, 'outside-codex-home')
    const outsideConfig = join(outsideCodexHome, 'config.toml')

    try {
      mkdirSync(agentHome)
      mkdirSync(outsideCodexHome)
      writeFileSync(outsideConfig, 'keep')
      symlinkSync(outsideCodexHome, join(agentHome, '.codex'), 'dir')

      await expect(retireLegacySharedCodexConfig(agentHome)).resolves.toBe('config_missing')
      expect(existsSync(outsideConfig)).toBe(true)
      expect(existsSync(join(outsideCodexHome, '.ankole-app-server.lock'))).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function writePortableFlock(path: string): void {
  writeFileSync(
    path,
    `#!/usr/bin/env python3
import fcntl
import os
import sys

args = sys.argv[1:]
if len(args) < 6 or args[0] != "-n" or args[1] != "-E" or args[3] != "-F":
    sys.exit(64)
busy_code = int(args[2])
fd = os.open(args[4], os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(busy_code)
os.set_inheritable(fd, True)
os.execvp(args[5], args[5:])
`
  )
  chmodSync(path, 0o755)
}

async function waitForFile(path: string): Promise<void> {
  const deadline = Date.now() + 5_000
  while (!existsSync(path)) {
    if (Date.now() >= deadline) throw new Error(`Timed out waiting for ${path}`)
    await Bun.sleep(10)
  }
}
