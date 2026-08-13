import { describe, expect, test } from 'bun:test'
import { WORKER_SHARE_ROOT } from '../src/core/agent-home-paths'
import { bubblewrapArgv } from '../src/tools/computer/bubblewrap'

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
})
