import { describe, expect, it } from 'bun:test'
import type { Computer } from '@agentbull/bullx-computer'
import { createBrowserTools } from './browser-tools'
import { executionScopeTag, type ComputerToolContext } from '../computer/context'

const SCOPE_TAG = executionScopeTag({ executionScopeId: 'test-scope' })

describe('browser tools', () => {
  // Pins the scoping split: the execution session is conversation-scoped
  // (agent uid + scope-tag hash) while the profile session is the bare agent uid,
  // so captures stay per-conversation but cookies/login are shared per agent.
  it('opens through bullx-browser with a conversation-scoped execution session and the agent-level profile', async () => {
    const calls: unknown[] = []
    const context = contextWithComputer({
      async runCommand(params: unknown) {
        calls.push(params)
        return finishedCommand(JSON.stringify({ ok: true, title: 'Example Domain' }))
      }
    })

    const tool = createBrowserTools(context).find(item => item.name === 'browser_open')
    expect(tool).toBeTruthy()
    const result = await tool!.execute('tc_browser_open', { url: 'https://example.com' })

    expect(result.details).toEqual({ exitCode: 0, result: { ok: true, title: 'Example Domain' } })
    expect(calls).toEqual([
      {
        cmd: 'bullx-browser',
        args: [
          '--json',
          'open',
          '--session',
          `agent_123--s-${SCOPE_TAG}`,
          '--profile-session',
          'agent_123',
          '--url',
          'https://example.com',
          '--profile-mode',
          'ephemeral'
        ],
        timeoutMs: 120000,
        signal: undefined
      }
    ])
  })

  // Pins the two-step run contract: the script is written to a session/task
  // namespaced file first, then the CLI is pointed at that path (not passed the
  // source inline), and the seconds-based timeout is converted to ms.
  it('writes browser_run scripts into the computer before invoking the CLI', async () => {
    const commands: unknown[] = []
    const writes: unknown[] = []
    const context = contextWithComputer({
      fs: {
        async writeFiles(files: unknown, opts: unknown) {
          writes.push({ files, opts })
        }
      },
      async runCommand(params: unknown) {
        commands.push(params)
        return finishedCommand(JSON.stringify({ ok: true, operation: 'run' }))
      }
    })

    const tool = createBrowserTools(context).find(item => item.name === 'browser_run')
    expect(tool).toBeTruthy()
    await tool!.execute('tc_browser_run', {
      script: 'print("hello")',
      taskId: 'smoke',
      timeout: 7
    })

    expect(writes).toEqual([
      {
        files: [
          {
            path: `user-files/browser/tasks/agent_123--s-${SCOPE_TAG}/smoke/input_script.py`,
            content: 'print("hello")'
          }
        ],
        opts: { cwd: '/workspace', signal: undefined }
      }
    ])
    expect(commands).toEqual([
      {
        cmd: 'bullx-browser',
        args: [
          '--json',
          'run',
          '--session',
          `agent_123--s-${SCOPE_TAG}`,
          '--profile-session',
          'agent_123',
          '--task-id',
          'smoke',
          '--script',
          `/workspace/user-files/browser/tasks/agent_123--s-${SCOPE_TAG}/smoke/input_script.py`,
          '--profile-mode',
          'persistent',
          '--timeout-ms',
          '7000'
        ],
        timeoutMs: 7000,
        signal: undefined
      }
    ])
  })
})

function contextWithComputer(computer: unknown): ComputerToolContext {
  return {
    agentUid: 'agent_123',
    executionScopeId: 'test-scope',
    getComputer: async () => computer as Computer,
    backgroundIds: new Set()
  }
}

function finishedCommand(output: string) {
  return {
    exitCode: 0,
    async output() {
      return output
    }
  }
}
