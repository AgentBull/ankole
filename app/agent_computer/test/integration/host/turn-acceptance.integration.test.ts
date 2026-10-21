import { create, toBinary } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { BrowserRuntime } from '../../../src/browser-runtime'
import { createEnvelope, envelopeHeader, RPCResponseSchema, type Envelope } from '../../../src/fabric/envelope_proto'
import {
  SignalEnvelopeSchema,
  TurnControlSchema,
  TurnStartSchema
} from '../../../src/fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import { ActorTurnAbortResponseSchema } from '../../../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { RuntimeFabricTransportError, type EnvelopeSender } from '../../../src/fabric/fabric'
import { jobTurnRefToProto } from '../../../src/lanes/session_lane'
import { RuntimeRPCClient } from '../../../src/lanes/rpc_lane'
import { ActiveTurns } from '../../../src/worker/active_turns'
import type { WorkerConfig } from '../../../src/worker/config'
import { WorkerDrainState } from '../../../src/worker/drain'
import { Slots } from '../../../src/worker/lifecycle_messages'

const turn = {
  session: { agent_uid: 'agent-1', session_id: 'job:1000' },
  job_id: 1000,
  attempt: 1,
  signal_id: '00000000-0000-0000-0000-000000000101'
}

function fixture(plans: Array<Error | undefined>, maxConcurrentSlots = 1) {
  const root = mkdtempSync(join(tmpdir(), 'ank-accept-'))
  const config: WorkerConfig = {
    endpoint: 'ws://127.0.0.1:4000/runtime-fabric/worker',
    workerAuthKey: 'secret',
    workerID: 'agent-1',
    incarnationID: 'incarnation-a',
    agentHomeRoot: root,
    builtinSkillsRoot: join(import.meta.dir, '../../../../library'),
    browser: { daemonEntry: '/bin/true', runnerPath: '/bin/true', localChromiumExecutable: '/bin/true' },
    maxConcurrentSlots
  }
  const sent: Envelope[] = []
  let resume!: () => void
  const ready = new Promise<void>(resolve => {
    resume = resolve
  })
  const send: EnvelopeSender = async envelope => {
    sent.push(envelope)
    if (envelope.body.case === 'turnAccepted') {
      const error = plans.shift()
      if (error) throw error
    }
    if (envelope.body.case === 'rpcRequest' && envelope.body.value.method === 'session_turn.abort') {
      const request = envelope.body.value
      queueMicrotask(() =>
        rpc.resolve(
          create(RPCResponseSchema, {
            requestId: request.requestId,
            payload: toBinary(ActorTurnAbortResponseSchema, create(ActorTurnAbortResponseSchema))
          })
        )
      )
    }
  }
  const rpc = new RuntimeRPCClient(send, {
    awaitReady: signal =>
      new Promise<void>((resolve, reject) => {
        const aborted = () => reject(signal!.reason)
        signal?.addEventListener('abort', aborted, { once: true })
        void ready.then(() => {
          signal?.removeEventListener('abort', aborted)
          resolve()
        })
      })
  })
  const drain = new WorkerDrainState()
  const slots = new Slots(config, drain, send)
  const active = new ActiveTurns(config, {} as BrowserRuntime, send, rpc, drain, slots)
  const input = createEnvelope({
    ...envelopeHeader('start'),
    body: {
      case: 'turnStart',
      value: create(TurnStartSchema, {
        mode: 'start',
        fetchRuntimeConfig: { ssrfFilter: true },
        turn: jobTurnRefToProto(turn),
        signal: create(SignalEnvelopeSchema, {
          signalId: turn.signal_id,
          type: 'im.message.addressed'
        })
      })
    }
  })
  const stopping = createEnvelope({
    ...envelopeHeader('stop'),
    body: {
      case: 'turnControl',
      value: create(TurnControlSchema, {
        turn: jobTurnRefToProto(turn),
        command: 'stop'
      })
    }
  })
  return {
    active,
    drain,
    slots,
    input,
    stopping,
    sent,
    resume,
    acceptanceCount: () => sent.filter(envelope => envelope.body.case === 'turnAccepted').length,
    executionCount: () =>
      sent.filter(envelope => envelope.body.case === 'rpcRequest' && envelope.body.value.method === 'files.list')
        .length,
    cleanup: async () => {
      await active.control(stopping)
      await until(() => drain.activeTaskCount === 0)
      rpc.close()
      rmSync(root, { recursive: true, force: true })
    }
  }
}

async function until(predicate: () => boolean) {
  const deadline = Date.now() + 1000
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('local Turn lifecycle did not settle')
    await Bun.sleep(1)
  }
}

describe('Turn acceptance before execution', () => {
  for (const [accepted, maxConcurrentSlots] of [
    [true, 2],
    [false, 2],
    [true, 1],
    [false, 1]
  ] as const) {
    it(`${accepted ? 'releases' : 'retains'} the old attempt when a replacement is ${accepted ? 'accepted' : 'rejected'} with ${maxConcurrentSlots} slot(s)`, async () => {
      const f = fixture(
        [
          undefined,
          accepted ? undefined : new RuntimeFabricTransportError('rejected', 'run_closed', { reason: 'run_closed' })
        ],
        maxConcurrentSlots
      )
      const replacement = { ...turn, attempt: 2 }
      const nextInput = createEnvelope({
        ...envelopeHeader('replacement'),
        body: {
          case: 'turnStart',
          value: create(TurnStartSchema, {
            mode: 'start',
            fetchRuntimeConfig: { ssrfFilter: true },
            turn: jobTurnRefToProto(replacement),
            signal: create(SignalEnvelopeSchema, { signalId: turn.signal_id, type: 'im.message.addressed' })
          })
        }
      })
      const stopReplacement = createEnvelope({
        ...envelopeHeader('stop-replacement'),
        body: {
          case: 'turnControl',
          value: create(TurnControlSchema, { turn: jobTurnRefToProto(replacement), command: 'stop' })
        }
      })

      try {
        await f.active.start(f.input)
        await until(() => f.executionCount() === 1)
        await f.active.start(nextInput)
        await until(() => f.acceptanceCount() === 2 && f.drain.activeTaskCount === 1)
        expect(f.executionCount()).toBe(accepted ? 2 : 1)
        expect(f.active.size).toBe(1)
        // A full Worker hands the old attempt's slot to the replacement instead
        // of a worker_busy rejection; the slot count never exceeds the attempts.
        expect(f.slots.used()).toBe(1)
        expect(
          f.sent.filter(
            envelope => envelope.body.case === 'rpcRequest' && envelope.body.value.method === 'session_turn.abort'
          )
        ).toHaveLength(0)
        await f.active.control(accepted ? stopReplacement : f.stopping)
        await until(() => f.active.size === 0)
        expect(f.slots.used()).toBe(0)
      } finally {
        await f.active.control(stopReplacement)
        await f.cleanup()
      }
    })
  }

  it('keeps one slot accounted across three attempts when the middle attempt is retired while confirming', async () => {
    // Attempt 1 executes. Attempt 2 takes its slot and waits on an uncertain
    // ACK. Attempt 3 takes attempt 2's slot and is accepted, which retires
    // attempts 1 and 2. The slot must follow attempt 3, not return to attempt 1.
    const f = fixture([undefined, new RuntimeFabricTransportError('socket_closed', 'closed'), undefined])
    const attemptInput = (attempt: number) =>
      createEnvelope({
        ...envelopeHeader(`attempt-${attempt}`),
        body: {
          case: 'turnStart',
          value: create(TurnStartSchema, {
            mode: 'start',
            fetchRuntimeConfig: { ssrfFilter: true },
            turn: jobTurnRefToProto({ ...turn, attempt }),
            signal: create(SignalEnvelopeSchema, { signalId: turn.signal_id, type: 'im.message.addressed' })
          })
        }
      })
    const stopAttempt = (attempt: number) =>
      createEnvelope({
        ...envelopeHeader(`stop-attempt-${attempt}`),
        body: {
          case: 'turnControl',
          value: create(TurnControlSchema, { turn: jobTurnRefToProto({ ...turn, attempt }), command: 'stop' })
        }
      })

    try {
      await f.active.start(f.input)
      await until(() => f.executionCount() === 1)
      await f.active.start(attemptInput(2))
      await Bun.sleep(1)
      expect(f.active.size).toBe(2)
      expect(f.slots.used()).toBe(1)
      await f.active.start(attemptInput(3))
      await until(() => f.executionCount() === 2 && f.active.size === 1)
      expect(f.slots.used()).toBe(1)
      await f.active.control(stopAttempt(3))
      await until(() => f.active.size === 0)
      expect(f.slots.used()).toBe(0)
    } finally {
      f.resume()
      await f.active.control(stopAttempt(3))
      await f.cleanup()
    }
  })

  it('returns without blocking the receive loop and reconfirms one pending attempt before exactly one execution', async () => {
    const f = fixture([new RuntimeFabricTransportError('socket_closed', 'closed'), undefined])
    try {
      await f.active.start(f.input)
      await f.active.start(f.input)
      await Bun.sleep(1)
      expect(f.acceptanceCount()).toBe(1)
      expect(f.executionCount()).toBe(0)
      expect(f.slots.used()).toBe(1)
      f.resume()
      await until(() => f.executionCount() === 1)
      await f.active.start(f.input)
      await Bun.sleep(1)
      expect(f.acceptanceCount()).toBe(3)
      expect(f.executionCount()).toBe(1)
    } finally {
      await f.cleanup()
    }
  })

  it('retains an already running attempt across a duplicate uncertain ACK', async () => {
    const f = fixture([undefined, new RuntimeFabricTransportError('timeout', 'no ACK'), undefined])
    try {
      await f.active.start(f.input)
      await until(() => f.executionCount() === 1)
      await f.active.start(f.input)
      await f.active.start(f.input)
      await Bun.sleep(1)
      expect(f.acceptanceCount()).toBe(2)
      expect(f.active.size).toBe(1)
      expect(f.executionCount()).toBe(1)
      f.resume()
      await until(() => f.acceptanceCount() === 3)
      expect(f.executionCount()).toBe(1)
    } finally {
      await f.cleanup()
    }
  })

  for (const reason of ['background_agent_job_attempt_changed', 'run_closed']) {
    it(`releases a fresh explicitly rejected ${reason} attempt without executing`, async () => {
      const f = fixture([new RuntimeFabricTransportError('rejected', reason, { reason })])
      try {
        await f.active.start(f.input)
        await until(() => f.drain.activeTaskCount === 0)
        expect(f.executionCount()).toBe(0)
        expect(f.active.size).toBe(0)
        expect(f.slots.used()).toBe(0)
        expect(f.sent.filter(envelope => envelope.body.case === 'rpcRequest')).toHaveLength(0)
      } finally {
        await f.cleanup()
      }
    })
  }

  it('stops only the already running attempt when its duplicate is explicitly invalid', async () => {
    const f = fixture([undefined, new RuntimeFabricTransportError('rejected', 'run_closed', { reason: 'run_closed' })])
    try {
      await f.active.start(f.input)
      await until(() => f.executionCount() === 1)
      await f.active.start(f.input)
      await until(() => f.drain.activeTaskCount === 0)
      expect(f.active.size).toBe(0)
      expect(f.slots.used()).toBe(0)
      expect(
        f.sent.filter(
          envelope => envelope.body.case === 'rpcRequest' && envelope.body.value.method === 'session_turn.abort'
        )
      ).toHaveLength(0)
    } finally {
      await f.cleanup()
    }
  })

  for (const command of ['stop', 'drain']) {
    it(`does not execute a pending attempt after ${command}`, async () => {
      const f = fixture([new RuntimeFabricTransportError('socket_closed', 'closed'), undefined])
      try {
        await f.active.start(f.input)
        await Bun.sleep(1)
        if (command === 'stop') await f.active.control(f.stopping)
        else {
          f.drain.begin('sigterm')
          f.active.beginDrain()
        }
        await until(() => f.drain.activeTaskCount === 0)
        f.resume()
        await Bun.sleep(1)
        expect(f.acceptanceCount()).toBe(1)
        expect(f.executionCount()).toBe(0)
        expect(f.slots.used()).toBe(0)
      } finally {
        await f.cleanup()
      }
    })
  }

  it('reports an unrelated rejection instead of silently treating it as an invalid attempt', async () => {
    const f = fixture([new RuntimeFabricTransportError('rejected', 'wrong_stream', { reason: 'wrong_stream' })])
    try {
      await f.active.start(f.input)
      await until(() => f.drain.activeTaskCount === 0)
      expect(f.executionCount()).toBe(0)
      expect(
        f.sent.filter(
          envelope => envelope.body.case === 'rpcRequest' && envelope.body.value.method === 'session_turn.abort'
        )
      ).toHaveLength(1)
      expect(f.slots.used()).toBe(0)
    } finally {
      await f.cleanup()
    }
  })
})
