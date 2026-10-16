import { create } from '@bufbuild/protobuf'
import { JSONPassthroughResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { describe, expect, it } from 'bun:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startDriveCLIBridge } from '../src/cli/drive/drive-cli-bridge'
import { startWebhookCLIBridge, webhookRPCRequester } from '../src/cli/webhooks/webhook-cli-bridge'
import {
  startAutomationJobCLIBridge,
  automationJobRPCRequester
} from '../src/cli/automation-jobs/automation-job-cli-bridge'
import {
  AUTOMATION_JOB_CLI_SOCKET_ENV,
  DRIVE_CLI_SOCKET_ENV,
  WEBHOOK_CLI_SOCKET_ENV
} from '../src/core/execution/turn_runtime_env'
import { jsonBytes } from '../src/fabric/envelope_proto'
import type { RPCRequester } from '../src/lanes/rpc_lane'
import { FakeDrive } from './support/fake-drive'

describe('CLI shell entrypoints', () => {
  it('uses each family socket and keeps stdout, error exit and bound read policy', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-cli-entry-'))
    const run = { session: { session_id: 'conversation:cli' }, signal_id: 'signal-cli' }
    const calls: Array<{ method: string; frame: unknown; retry: boolean | undefined }> = []
    const rpc = (async (method, _payload, frame, opts) => {
      calls.push({ method, frame, retry: opts?.retryOnDisconnect })
      if (method === 'webhook.endpoint.list') {
        return create(JSONPassthroughResponseSchema, { bodyJson: jsonBytes({ method }) })
      }
      if (method === 'automation_job.list') {
        return create(JSONPassthroughResponseSchema, { bodyJson: jsonBytes({ method }) })
      }
      throw new Error(`Unexpected RPC: ${method}`)
    }) as RPCRequester
    const bridges = [
      {
        name: 'drive/drive-cli.ts',
        env: DRIVE_CLI_SOCKET_ENV,
        bridge: startDriveCLIBridge({ drive: new FakeDrive(root).drive(), workspaceRoot: root, socketRoot: root })
      },
      {
        name: 'webhooks/webhook-cli.ts',
        env: WEBHOOK_CLI_SOCKET_ENV,
        bridge: startWebhookCLIBridge({ requestWebhookRPC: webhookRPCRequester(rpc, run), socketRoot: root })
      },
      {
        name: 'automation-jobs/automation-job-cli.ts',
        env: AUTOMATION_JOB_CLI_SOCKET_ENV,
        bridge: startAutomationJobCLIBridge({
          drive: new FakeDrive(root).drive(),
          requestAutomationJobRPC: automationJobRPCRequester(rpc, run),
          socketRoot: root
        })
      }
    ]
    try {
      for (const { name, env, bridge } of bridges) {
        const entry = join(import.meta.dir, '../src/cli', name)
        const child = Bun.spawn([process.execPath, entry, 'list'], {
          env: { ...process.env, [env]: bridge.socketPath },
          stdout: 'pipe',
          stderr: 'pipe'
        })
        const [stdout, stderr, exit] = await Promise.all([
          new Response(child.stdout).text(),
          new Response(child.stderr).text(),
          child.exited
        ])
        expect(exit).toBe(0)
        expect(stderr).toBe('')
        expect(JSON.parse(stdout)).toBeObject()
        const invalid = Bun.spawn([process.execPath, entry, 'invalid-operation'], {
          env: { ...process.env, [env]: bridge.socketPath },
          stdout: 'pipe',
          stderr: 'pipe'
        })
        const [invalidOut, invalidError, invalidExit] = await Promise.all([
          new Response(invalid.stdout).text(),
          new Response(invalid.stderr).text(),
          invalid.exited
        ])
        expect(invalidExit).toBe(1)
        expect(invalidOut).toBe('')
        expect(invalidError).toContain('Usage:')
      }
      expect(calls).toEqual([
        { method: 'webhook.endpoint.list', frame: { run }, retry: true },
        { method: 'automation_job.list', frame: { run }, retry: true }
      ])
    } finally {
      for (const { bridge } of bridges) bridge.close()
      rmSync(root, { recursive: true, force: true })
    }
  })
})
