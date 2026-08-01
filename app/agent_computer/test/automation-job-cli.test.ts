import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  startAutomationJobCLIBridge,
  validatedJobDirectory
} from '../src/cli/automation-jobs/automation-job-cli-bridge'
import { requestAutomationJobCLI } from '../src/cli/automation-jobs/automation-job-cli-client'
import { AUTOMATION_JOB_CLI_HELP, commandFromArgs } from '../src/cli/automation-jobs/automation-job-cli'
import {
  rpcMethods,
  type AutomationJobManagementRPCMethod,
  type AutomationJobRPCRequester
} from '../src/lanes/rpc_lane'

describe('automation job CLI', () => {
  it('parses the management commands and rejects irrelevant options', () => {
    expect(commandFromArgs(['create', '--dir', './automation/price', '--label', 'Watch 7709'], '/agents/a')).toEqual({
      operation: 'create',
      directory_path: './automation/price',
      cwd: '/agents/a',
      label: 'Watch 7709',
      wake_on_failure: false
    })
    expect(commandFromArgs(['list', '--limit', '20'])).toEqual({ operation: 'list', limit: 20 })
    expect(commandFromArgs(['show', '--id', '1000', '--runs', '50'])).toEqual({
      operation: 'show',
      automation_job_id: 1000,
      runs: 50
    })
    expect(commandFromArgs(['cancel', '--id', '1001'])).toEqual({
      operation: 'cancel',
      automation_job_id: 1001
    })

    expect(() => commandFromArgs(['list', '--wake-on-failure'])).toThrow('unknown automation job CLI option')
    expect(() => commandFromArgs(['show', '--id', '999'])).toThrow()
    expect(() => commandFromArgs(['show', '--id', '1000', '--runs', '101'])).toThrow()
  })

  it('resolves the directory and main.ts inside the current Agent Home before creating', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-automation-cli-'))
    const agentHome = join(root, 'agent-1')
    const directory = join(agentHome, 'automation', 'price')
    mkdirSync(directory, { recursive: true })
    writeFileSync(join(directory, 'main.ts'), 'console.log("ok")\n')

    const calls: Array<{
      method: AutomationJobManagementRPCMethod
      payload: Record<string, unknown>
    }> = []
    const requester = (async (method, payload) => {
      calls.push({ method, payload })
      return { status: 'ok' }
    }) as AutomationJobRPCRequester
    const bridge = startAutomationJobCLIBridge({
      agentHome,
      requestAutomationJobRPC: requester,
      socketRoot: root
    })

    try {
      await requestAutomationJobCLI(bridge.socketPath, {
        operation: 'create',
        directory_path: './automation/price',
        cwd: agentHome,
        label: 'Watch 7709',
        wake_on_failure: true
      })
      await requestAutomationJobCLI(bridge.socketPath, { operation: 'list', limit: 10 })
      await requestAutomationJobCLI(bridge.socketPath, {
        operation: 'show',
        automation_job_id: 1000,
        runs: 5
      })
      await requestAutomationJobCLI(bridge.socketPath, {
        operation: 'cancel',
        automation_job_id: 1000
      })

      expect(calls).toEqual([
        {
          method: rpcMethods.automationJobCreate,
          payload: {
            directoryPath: realpathSync(directory),
            label: 'Watch 7709',
            wakeOnFailure: true
          }
        },
        { method: rpcMethods.automationJobList, payload: { limit: 10 } },
        {
          method: rpcMethods.automationJobShow,
          payload: { automationJobId: '1000', runs: 5 }
        },
        {
          method: rpcMethods.automationJobCancel,
          payload: { automationJobId: '1000' }
        }
      ])
    } finally {
      bridge.close()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects a directory or entrypoint that resolves through a symlink outside Agent Home', () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-automation-boundary-'))
    const agentHome = join(root, 'agent-1')
    const outside = join(root, 'outside')
    mkdirSync(agentHome, { recursive: true })
    mkdirSync(outside, { recursive: true })
    writeFileSync(join(outside, 'main.ts'), 'console.log("outside")\n')
    symlinkSync(outside, join(agentHome, 'escaped-directory'))

    const inside = join(agentHome, 'inside')
    mkdirSync(inside)
    symlinkSync(join(outside, 'main.ts'), join(inside, 'main.ts'))

    try {
      expect(() => validatedJobDirectory(agentHome, agentHome, './escaped-directory')).toThrow(
        'must resolve inside the current Agent Home'
      )
      expect(() => validatedJobDirectory(agentHome, agentHome, './inside')).toThrow(
        'main.ts must resolve inside the job directory'
      )
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('keeps the finalized help contract at the capability address', () => {
    const normalized = AUTOMATION_JOB_CLI_HELP.replace(/\s+/g, ' ')
    expect(normalized).toContain('deterministic consumer for triggers this conversation creates')
    expect(normalized).toContain('A run with no emitEvent call is a silent, completed consumption')
    expect(normalized).toContain('Runs can overlap and deliveries can repeat')
    expect(normalized).toContain('These SDK functions exist only in a platform run')
    expect(normalized).toContain(
      'the mcporter CLI is in the image, reads ~/.mcporter/mcporter.json from the Agent Home'
    )
    expect(normalized).toContain('mcporter --help documents commands and config')
    expect(normalized).toContain('After registration, use a test trigger to check each SDK branch')
    expect(normalized).toContain('whatever is on disk at fire time is what runs')
    expect(normalized).toContain('Cancel the triggers that point at a job before cancelling the job')
    expect(normalized).toContain('show-automation-job-cli --id <automation-job-id> [--runs <1-100>]')
  })
})
