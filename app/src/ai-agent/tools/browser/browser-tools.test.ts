import 'reflect-metadata'
import { describe, expect, it } from 'bun:test'
import type { Computer } from '@agentbull/bullx-computer'
import { createBrowserTools } from './browser-tools'
import type { ComputerToolContext } from '../computer/context'

describe('browser tools', () => {
  it('opens through bullx-browser with the agent UID as the default session', async () => {
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
            path: 'user-files/browser/tasks/agent_123/smoke/input_script.py',
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
          'agent_123',
          '--task-id',
          'smoke',
          '--script',
          '/workspace/user-files/browser/tasks/agent_123/smoke/input_script.py',
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
