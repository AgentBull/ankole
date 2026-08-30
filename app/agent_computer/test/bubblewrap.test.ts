import { describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { WORKER_SHARE_ROOT } from '../src/core/agent-home-paths'
import { bubblewrapArgv } from '../src/sandbox/bubblewrap'

describe('bubblewrap Worker share', () => {
  test('binds the fixed Worker share into every sandbox', () => {
    const argv = bubblewrapArgv(
      {
        workspaceRoot: '/agents/agent-1',
        cwd: '/agents/agent-1/sessions/session-1',
        env: {
          PATH: '/usr/local/bin:/usr/bin:/bin',
          HOME: '/agents/agent-1',
          LANG: 'C.UTF-8'
        },
        commandArgv: ['/bin/true']
      },
      'strong'
    )

    const bindIndex = argv.findIndex(
      (value, index) =>
        value === '--bind' && argv[index + 1] === WORKER_SHARE_ROOT && argv[index + 2] === WORKER_SHARE_ROOT
    )
    expect(bindIndex).toBeGreaterThan(-1)
  })

  test('binds container sysfs read-only for native CPU runtimes', () => {
    const argv = bubblewrapArgv(
      {
        workspaceRoot: '/agents/agent-1',
        cwd: '/agents/agent-1/sessions/session-1',
        env: {
          PATH: '/usr/local/bin:/usr/bin:/bin',
          HOME: '/agents/agent-1',
          LANG: 'C.UTF-8'
        },
        commandArgv: ['/bin/true']
      },
      'strong'
    )

    const bindIndex = argv.findIndex(
      (value, index) => value === '--ro-bind' && argv[index + 1] === '/sys' && argv[index + 2] === '/sys'
    )
    expect(bindIndex).toBeGreaterThan(-1)
  })

  test('binds the Agent confidentiality policy read-only', () => {
    const agentHome = mkdtempSync(join(tmpdir(), 'ankole-bwrap-policy-'))
    const policyPath = join(agentHome, 'ConfidentialityPolicy.md')

    try {
      writeFileSync(policyPath, 'Policy body.\n')
      const argv = bubblewrapArgv(
        {
          workspaceRoot: agentHome,
          cwd: agentHome,
          env: {
            PATH: '/usr/local/bin:/usr/bin:/bin',
            HOME: agentHome,
            LANG: 'C.UTF-8'
          },
          commandArgv: ['/bin/true']
        },
        'strong'
      )

      const bindIndex = argv.findIndex(
        (value, index) => value === '--ro-bind' && argv[index + 1] === policyPath && argv[index + 2] === policyPath
      )
      const agentHomeBindIndex = argv.findIndex(
        (value, index) => value === '--bind' && argv[index + 1] === agentHome && argv[index + 2] === agentHome
      )
      expect(agentHomeBindIndex).toBeGreaterThan(-1)
      expect(bindIndex).toBeGreaterThan(agentHomeBindIndex)
    } finally {
      rmSync(agentHome, { recursive: true, force: true })
    }
  })
})
