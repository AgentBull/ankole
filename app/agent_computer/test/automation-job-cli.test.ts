import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startAutomationJobCLIBridge } from '../src/cli/automation-jobs/automation-job-cli-bridge'
import { requestSocketLineBridge } from '../src/core/socket-line-bridge'
import { AUTOMATION_JOB_CLI_HELP, commandFromArgs } from '../src/cli/automation-jobs/automation-job-cli'
import { RPCRejectedError, RPCTimeoutError } from '../src/lanes/rpc_lane'
import {
  type AutomationJobManagementRPCMethod,
  type AutomationJobRPCRequester
} from '../src/cli/automation-jobs/automation-job-cli-bridge'
import { FakeDrive } from './support/fake-drive'

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

  it('copies the job directory into a new drive folder before creating', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-automation-cli-'))
    const agentHome = join(root, 'agent-1')
    const directory = join(agentHome, 'automation', 'price')
    mkdirSync(join(directory, 'lib'), { recursive: true })
    writeFileSync(join(directory, 'main.ts'), 'console.log("ok")\n')
    writeFileSync(join(directory, 'lib', 'parse.ts'), 'export {}\n')
    const drive = new FakeDrive(agentHome)

    const calls: Array<{
      method: AutomationJobManagementRPCMethod
      payload: Record<string, unknown>
    }> = []
    const requester = (async (method, payload) => {
      calls.push({ method, payload })
      return { status: 'ok' }
    }) as AutomationJobRPCRequester
    const bridge = startAutomationJobCLIBridge({
      drive: drive.drive(),
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

      const drivePrefix = String(calls[0]?.payload.drivePrefix)
      expect(drivePrefix).toMatch(/^automation\/price-[0-9a-f]{8}$/)
      expect(drive.paths('automation')).toEqual([`${drivePrefix}/lib/parse.ts`, `${drivePrefix}/main.ts`])
      expect(drive.text(`${drivePrefix}/main.ts`)).toBe('console.log("ok")\n')
      expect(calls).toEqual([
        {
          method: 'automation_job.create',
          payload: { drivePrefix, label: 'Watch 7709', wakeOnFailure: true }
        },
        { method: 'automation_job.list', payload: { limit: 10 } },
        {
          method: 'automation_job.show',
          payload: { automationJobId: '1000', runs: 5 }
        },
        {
          method: 'automation_job.cancel',
          payload: { automationJobId: '1000' }
        }
      ])
    } finally {
      bridge.close()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('removes the drive folder when the control plane rejects registration', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-automation-cli-failure-'))
    const agentHome = join(root, 'agent-1')
    const directory = join(agentHome, 'automation', 'price')
    mkdirSync(directory, { recursive: true })
    writeFileSync(join(directory, 'main.ts'), 'console.log("ok")\n')
    const drive = new FakeDrive(agentHome)
    const requester = (async () => {
      throw new RPCRejectedError('automation_job.create', {
        code: 'work_access_revoked',
        message: 'work access revoked'
      })
    }) as AutomationJobRPCRequester
    const bridge = startAutomationJobCLIBridge({
      drive: drive.drive(),
      requestAutomationJobRPC: requester,
      socketRoot: root
    })

    try {
      await expect(
        requestAutomationJobCLI(bridge.socketPath, {
          operation: 'create',
          directory_path: directory,
          cwd: agentHome,
          label: 'Watch 7709',
          wake_on_failure: false
        })
      ).rejects.toThrow('work access revoked')
      expect(drive.paths()).toEqual([])
    } finally {
      bridge.close()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it.each([
    new RPCTimeoutError('automation_job.create'),
    new RPCRejectedError('automation_job.create', { code: 'rpc_handler_failed' })
  ])('keeps the script when creation can have committed before the error: %s', async error => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-automation-cli-unknown-'))
    const agentHome = join(root, 'agent-1')
    const directory = join(agentHome, 'automation', 'price')
    mkdirSync(directory, { recursive: true })
    writeFileSync(join(directory, 'main.ts'), 'console.log("ok")\n')
    const drive = new FakeDrive(agentHome)
    let registeredPrefix = ''
    const requester = (async (_method, payload) => {
      registeredPrefix = String((payload as { drivePrefix: string }).drivePrefix)
      throw error
    }) as AutomationJobRPCRequester
    const bridge = startAutomationJobCLIBridge({
      drive: drive.drive(),
      requestAutomationJobRPC: requester,
      socketRoot: root
    })

    try {
      await expect(
        requestAutomationJobCLI(bridge.socketPath, {
          operation: 'create',
          directory_path: directory,
          cwd: agentHome,
          label: 'Watch 7709',
          wake_on_failure: false
        })
      ).rejects.toThrow('Run list-automation-jobs-cli and look for this drive_prefix before retrying create')
      expect(drive.paths()).toEqual([`${registeredPrefix}/main.ts`])
      expect(drive.text(`${registeredPrefix}/main.ts`)).toBe('console.log("ok")\n')
    } finally {
      bridge.close()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects a directory without a regular main.ts before copying anything', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-automation-boundary-'))
    const agentHome = join(root, 'agent-1')
    const outside = join(root, 'outside')
    const linked = join(agentHome, 'linked')
    mkdirSync(linked, { recursive: true })
    mkdirSync(outside, { recursive: true })
    writeFileSync(join(outside, 'main.ts'), 'console.log("outside")\n')
    symlinkSync(join(outside, 'main.ts'), join(linked, 'main.ts'))
    const drive = new FakeDrive(agentHome)
    const requester = (async () => ({ status: 'ok' })) as AutomationJobRPCRequester
    const bridge = startAutomationJobCLIBridge({
      drive: drive.drive(),
      requestAutomationJobRPC: requester,
      socketRoot: root
    })
    const create = (directory_path: string) =>
      requestAutomationJobCLI(bridge.socketPath, {
        operation: 'create',
        directory_path,
        cwd: agentHome,
        label: 'Watch 7709',
        wake_on_failure: false
      })

    try {
      await expect(create('./linked')).rejects.toThrow('must contain a regular main.ts file')
      await expect(create('./missing')).rejects.toThrow('automation job path must be a directory')
      expect(drive.paths()).toEqual([])
    } finally {
      bridge.close()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('keeps the finalized help contract at the capability address', () => {
    const normalized = AUTOMATION_JOB_CLI_HELP.replace(/\s+/g, ' ')
    expect(normalized).toContain('deterministic consumer for triggers this conversation creates')
    expect(normalized).toContain('A run with no emitEvent call is a silent, completed consumption')
    expect(normalized).toContain('Runs can overlap and deliveries can repeat')
    expect(normalized).toContain('These SDK functions exist only in a platform run')
    expect(normalized).toContain('Each run receives a generated MCPORTER_CONFIG and the current Agent WorkerEnv')
    expect(normalized).toContain('Bun.spawn argv for mcporter call server.tool --json - --output json')
    expect(normalized).toContain('After registration, use a test trigger to check each SDK branch')
    expect(normalized).toContain('every run uses what that folder holds at fire time')
    expect(normalized).toContain('Cancel the triggers that point at a job before cancelling the job')
    expect(normalized).toContain('show-automation-job-cli --id <automation-job-id> [--runs <1-100>]')
  })
})

function requestAutomationJobCLI(socketPath: string, command: unknown) {
  return requestSocketLineBridge(
    socketPath,
    JSON.stringify(command),
    'automation job CLI bridge returned an invalid response'
  )
}
