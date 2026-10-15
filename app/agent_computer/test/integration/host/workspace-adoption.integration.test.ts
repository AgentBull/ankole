import { mkdirAgentSync } from '../../../src/common/agent-user'
import { Slots } from '../../../src/worker/lifecycle_messages'
import { AgentConversationContextResponseSchema } from '../../../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { afterEach, describe, expect, it } from 'bun:test'
import { create, fromBinary, toBinary } from '@bufbuild/protobuf'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { BrowserRuntime } from '../../../src/browser-runtime'
import { jsonBytes, RPCResponseSchema, type Envelope } from '../../../src/fabric/envelope_proto'
import {
  SessionKeySchema,
  RunRefSchema,
  ToolCallSchema,
  WorkspaceCloseSchema,
  WorkspaceOpenSchema,
  WorkspaceReady_Reason
} from '../../../src/fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import { RuntimeRPCClient, rpcOperations, type ControlPlaneOwnedRPCMethod } from '../../../src/lanes/rpc_lane'
import { WorkerDrainState } from '../../../src/worker/drain'
import { Workspaces } from '../../../src/worker/workspaces'
import type { WorkerConfig } from '../../../src/worker/config'
import { FakeDrive } from '../../support/fake-drive'

const cleanups: Array<() => Promise<void>> = []
afterEach(async () => {
  for (const cleanup of cleanups.splice(0)) await cleanup()
})

function fixture(slots = 2, capacityChanged = async (): Promise<void> => {}) {
  const root = mkdtempSync(join(tmpdir(), 'ankole-workspace-adoption-'))
  mkdirAgentSync(root, 0o700)
  const config: WorkerConfig = {
    endpoint: 'ws://unused',
    workerAuthKey: 'test',
    workerID: 'workspace-test',
    incarnationID: crypto.randomUUID(),
    agentHomeRoot: root,
    builtinSkillsRoot: join(import.meta.dir, '../../../../library'),
    browser: { daemonEntry: '/bin/true', runnerPath: '/bin/true', localChromiumExecutable: '/bin/true' },
    maxConcurrentSlots: slots
  }
  const browser = new BrowserRuntime({ runtimeRoot: root, ...config.browser })
  const drive = new FakeDrive(root)
  const rpc = new RuntimeRPCClient(async envelope => {
    if (envelope.body.case !== 'rpcRequest') throw new Error('Expected a control-plane RPC request')
    const request = envelope.body.value
    const method = request.method as ControlPlaneOwnedRPCMethod
    const codec = rpcOperations[method]
    const payload = fromBinary(codec.request, request.payload)
    const data =
      method === 'worker_env.resolve'
        ? { vars: {}, operatorVars: {}, bindingVars: {} }
        : await drive.rpc(method as 'files.list', payload as never, undefined)
    rpc.resolve(
      create(RPCResponseSchema, {
        requestId: request.requestId,
        payload: toBinary(codec.response, create(codec.response, data as never))
      })
    )
  })
  const sent: Envelope[] = []
  let dropResult = false
  const drain = new WorkerDrainState()
  const sharedSlots = new Slots(config, drain, async () => capacityChanged())
  const spaces = new Workspaces(
    config,
    browser,
    async envelope => {
      if (envelope.body.case === 'toolResult' && dropResult) throw new Error('Connection lost')
      sent.push(envelope)
    },
    rpc,
    drain,
    sharedSlots
  )
  const run = create(RunRefSchema, {
    session: { sessionId: 'conversation:one' },
    signalId: '019a7d15-6b54-7ed9-ae76-78f7fd91e4d5'
  })
  const open = create(WorkspaceOpenSchema, {
    run,
    workspaceId: 10000n,
    agentContext: context('first'),
    fetchRuntimeConfig: { ssrfFilter: true },
    idleTimeoutMs: 300000n
  })
  const call = create(ToolCallSchema, {
    run,
    responseId: 'resp_test',
    callId: 'command-1',
    name: 'command',
    mode: 'execute',
    argumentsJson: jsonBytes({ command: `printf x >> '${join(root, 'effect')}'` })
  })
  cleanups.push(async () => {
    await spaces.close(create(WorkspaceCloseSchema, { run }))
    await browser.stop()
    rmSync(root, { recursive: true, force: true })
  })
  return {
    spaces,
    slots: sharedSlots,
    root,
    sent,
    run,
    open,
    call,
    setDrop: (value: boolean) => {
      dropResult = value
    }
  }
}

async function until(check: () => boolean, attempts = 400): Promise<void> {
  for (let n = 0; n < attempts; n++) {
    if (check()) return
    await Bun.sleep(25)
  }
  throw new Error('The workspace did not reach the expected boundary')
}

describe('real workspace command adoption', () => {
  it('synchronizes Agent documents on the first environment workspace and each new input', async () => {
    const f = fixture()
    for (const version of ['first', 'updated']) {
      const run = create(RunRefSchema, { ...f.run, signalId: `input-${version}` })
      f.spaces.open(create(WorkspaceOpenSchema, { ...f.open, run, agentContext: context(version) }))
      await until(() =>
        f.sent.some(e => e.body.case === 'workspaceReady' && e.body.value.run?.signalId === run.signalId)
      )
      for (const name of ['SOUL', 'MISSION', 'DESIGN', 'ConfidentialityPolicy']) {
        expect(readFileSync(join(f.root, `${name}.md`), 'utf8')).toBe(`${name} ${version}`)
      }
      if (version === 'updated') await f.spaces.close(create(WorkspaceCloseSchema, { run }))
    }
  })

  it('retains running commands and cached receipts across a lost connection without repeating an effect (G3)', async () => {
    const f = fixture()
    f.spaces.open(f.open)
    await until(() => f.sent.some(e => e.body.case === 'workspaceReady'))
    f.setDrop(true)
    const call = create(ToolCallSchema, {
      ...f.call,
      argumentsJson: jsonBytes({ command: `printf x >> '${join(f.root, 'effect')}'; sleep 0.2` })
    })
    f.spaces.call(call)
    await until(() => existsSync(join(f.root, 'effect')))
    f.spaces.call(create(ToolCallSchema, { ...call, mode: 'probe' }))
    await Bun.sleep(30)
    expect(f.sent.some(e => e.body.case === 'toolStatus')).toBe(false)
    await Bun.sleep(300)
    f.setDrop(false)
    f.spaces.call(create(ToolCallSchema, { ...call, mode: 'probe' }))
    await until(() => f.sent.some(e => e.body.case === 'toolResult'))
    expect(f.sent.find(e => e.body.case === 'toolResult')?.body).toMatchObject({ value: { isError: false } })
    expect(readFileSync(join(f.root, 'effect'), 'utf8')).toBe('x')
    f.spaces.call(call)
    await until(() => f.sent.filter(e => e.body.case === 'toolResult').length === 2)
    expect(readFileSync(join(f.root, 'effect'), 'utf8')).toBe('x')

    const unknown = create(ToolCallSchema, { ...call, callId: 'lost', mode: 'probe' })
    f.spaces.call(unknown)
    await until(() =>
      f.sent.some(
        e => e.body.case === 'toolStatus' && e.body.value.callId === 'lost' && e.body.value.state === 'unknown'
      )
    )
    expect(readFileSync(join(f.root, 'effect'), 'utf8')).toBe('x')
  })

  it('uses the same slot as a Job turn and opens after the Job releases it', async () => {
    const f = fixture(1)
    expect(f.slots.reserve()).toBe(true)
    f.spaces.open(f.open)
    await until(() => f.sent.some(e => e.body.case === 'workspaceReady'))
    const denied = f.sent.find(e => e.body.case === 'workspaceReady')!
    if (denied.body.case !== 'workspaceReady') throw new Error('expected readiness')
    expect(denied.body.value.reason).toBe(WorkspaceReady_Reason.CAPACITY)
    expect(f.spaces.size).toBe(0)
    f.sent.length = 0
    f.slots.release()
    f.spaces.open(f.open)
    await until(() => f.sent.some(e => e.body.case === 'workspaceReady'))
    const ready = f.sent.find(e => e.body.case === 'workspaceReady')!
    if (ready.body.case !== 'workspaceReady') throw new Error('expected readiness')
    expect(ready.body.value.reason).toBe(WorkspaceReady_Reason.READY)
    expect(f.slots.used()).toBe(1)
    await f.spaces.close(create(WorkspaceCloseSchema, { run: f.run }))
    expect(f.slots.used()).toBe(0)
  })

  it('waits for old commands to stop before replacing a workspace and enforces shared capacity (G3, G4)', async () => {
    const f = fixture(1)
    f.spaces.open(f.open)
    await until(() => f.sent.some(e => e.body.case === 'workspaceReady'))
    const other = create(RunRefSchema, {
      ...f.run,
      session: create(SessionKeySchema, { sessionId: 'conversation:two' })
    })
    f.spaces.open(create(WorkspaceOpenSchema, { ...f.open, run: other, workspaceId: 10001n }))
    await until(() =>
      f.sent.some(e => e.body.case === 'workspaceReady' && e.body.value.run?.session?.sessionId === 'conversation:two')
    )
    expect(
      f.sent.find(e => e.body.case === 'workspaceReady' && e.body.value.run?.session?.sessionId === 'conversation:two')
        ?.body
    ).toMatchObject({ value: { reason: WorkspaceReady_Reason.CAPACITY } })
    f.spaces.call(
      create(ToolCallSchema, {
        ...f.call,
        argumentsJson: jsonBytes({
          command: `touch '${join(f.root, 'started')}'; sleep 60; printf old >> '${join(f.root, 'effect')}'`
        })
      })
    )
    await until(() => existsSync(join(f.root, 'started')))
    const next = create(RunRefSchema, { ...f.run, signalId: '019a7d15-6b54-7ed9-ae76-78f7fd91e4d6' })
    f.spaces.open(create(WorkspaceOpenSchema, { ...f.open, run: next }))
    await until(() =>
      f.sent.some(e => e.body.case === 'workspaceReady' && e.body.value.run?.signalId === next.signalId)
    )
    f.spaces.call(
      create(ToolCallSchema, {
        ...f.call,
        run: next,
        argumentsJson: jsonBytes({ command: `printf fresh >> '${join(f.root, 'effect')}'` })
      })
    )
    await until(() => existsSync(join(f.root, 'effect')))
    expect(readFileSync(join(f.root, 'effect'), 'utf8')).toBe('fresh')
    await f.spaces.close(create(WorkspaceCloseSchema, { run: next }))
    expect(f.spaces.size).toBe(0)
  })

  it('keeps cleanup alive when capacity publication rejects during an idle close (G5)', async () => {
    let reports = 0
    const f = fixture(1, async () => {
      reports++
      throw new Error('Control plane is restarting')
    })
    f.spaces.open(create(WorkspaceOpenSchema, { ...f.open, idleTimeoutMs: 50n }))
    await until(() => f.sent.some(e => e.body.case === 'workspaceReady'))
    await until(() => f.spaces.size === 0)
    expect(reports).toBeGreaterThanOrEqual(2)
  })
})

function context(version: string) {
  return create(AgentConversationContextResponseSchema, {
    soul: `SOUL ${version}`,
    mission: `MISSION ${version}`,
    design: `DESIGN ${version}`,
    confidentialityPolicy: `ConfidentialityPolicy ${version}`
  })
}
