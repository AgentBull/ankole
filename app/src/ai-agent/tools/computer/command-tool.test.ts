import { describe, expect, it } from 'bun:test'
import type { Computer } from '@agentbull/bullx-computer'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'
import type { ComputerToolContext } from './context'

await loadTestEnvFiles()

const { createCommandTool } = await import('./command-tool')
const { createComputerTools } = await import('.')

describe('createCommandTool', () => {
  it('runs through stateless runCommand instead of the persistent shell', async () => {
    const calls: unknown[] = []
    // `runShellCommand` throws so the test fails loudly if `command` ever routes through the
    // persistent shell — statelessness is the contract that separates it from `terminal`.
    const computer = {
      async runCommand(params: unknown) {
        calls.push(params)
        return {
          exitCode: 0,
          async output() {
            return '/workspace\n'
          }
        }
      },
      async runShellCommand() {
        throw new Error('command tool must not use the persistent shell')
      }
    } as unknown as Computer
    const context: ComputerToolContext = {
      agentUid: 'agent_123',
      executionScopeId: 'test-scope',
      getComputer: async () => computer,
      backgroundIds: new Set()
    }

    const tool = createCommandTool(context)
    const result = await tool.execute('tc_command', {
      command: 'pwd',
      workdir: '/workspace',
      timeout: 3,
      env: { FOO: 'bar' }
    })

    expect(result.content).toEqual([{ type: 'text', text: 'exit_code=0\n/workspace\n' }])
    expect(result.details).toEqual({ exitCode: 0 })
    expect(calls).toEqual([
      {
        cmd: 'bash',
        args: ['-lc', 'pwd'],
        cwd: '/workspace',
        env: { FOO: 'bar' },
        timeoutMs: 3000,
        signal: undefined
      }
    ])
  })

  // Pins the exact tool set and its order as wired in index.ts; a reorder or accidental
  // add/drop of a tool should surface here.
  it('exposes command and terminal as separate computer tools', () => {
    const tools = createComputerTools(
      { agentUid: 'agent_123' },
      {
        resolveWorker: async () => ({
          agentUid: 'agent_123',
          worker: { workerId: 'dev', instanceId: 'i0', baseUrl: 'https://worker.local' },
          binding: { kind: 'implicit', reason: 'test' },
          tls: { caCert: 'CA', cert: 'CERT', key: 'KEY' }
        })
      }
    )

    expect(tools.map(tool => tool.name)).toEqual([
      'browser_doctor',
      'browser_open',
      'browser_extract',
      'browser_run',
      'codex_delegate',
      'command',
      'terminal',
      'interactive_terminal',
      'process',
      'read_file',
      'send_file',
      'patch'
    ])
  })
})
