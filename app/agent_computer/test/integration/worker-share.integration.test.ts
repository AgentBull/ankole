import { afterAll, beforeAll, describe, expect, test } from 'bun:test'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { WORKER_SHARE_ROOT } from '../../src/core/agent-home-paths'
import { bubblewrapArgv } from '../../src/sandbox/bubblewrap'

describe('Worker share across the real bubblewrap boundary', () => {
  let agentHome: string
  let workspaceRoot: string
  let markerPath: string

  beforeAll(() => {
    agentHome = mkdtempSync('/agents/ankole-worker-share-')
    workspaceRoot = join(agentHome, 'jobs', 'job-1')
    markerPath = join(WORKER_SHARE_ROOT, `ankole-worker-share-${process.pid}`)
    mkdirSync(workspaceRoot, { recursive: true })
    writeFileSync(markerPath, 'outside')
  })

  afterAll(() => {
    if (markerPath) rmSync(markerPath, { force: true })
    if (agentHome) rmSync(agentHome, { recursive: true, force: true })
  })

  test('reads and writes the same Worker-local file', () => {
    const argv = bubblewrapArgv(
      {
        workspaceRoot: agentHome,
        cwd: workspaceRoot,
        env: {
          PATH: '/usr/local/bin:/usr/bin:/bin',
          HOME: agentHome,
          LANG: 'C.UTF-8'
        },
        commandArgv: ['/bin/sh', '-lc', `test "$(cat ${markerPath})" = outside && printf inside > ${markerPath}`]
      },
      'strong'
    )
    const result = spawnSync(argv[0]!, argv.slice(1), {
      cwd: workspaceRoot,
      encoding: 'utf8',
      timeout: 10_000
    })

    expect(result.status, `${result.stderr}\n${result.stdout}`).toBe(0)
    expect(readFileSync(markerPath, 'utf8')).toBe('inside')
  })
})
