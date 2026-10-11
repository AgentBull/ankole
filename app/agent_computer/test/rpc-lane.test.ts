import { create, toBinary } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { RPCResponseSchema } from '../src/fabric/envelope_proto'
import { WorkerEnvResolveResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { RPCTimeoutError, RuntimeRPCClient } from '../src/lanes/rpc_lane'
import { RuntimeFabricTransportError, type EnvelopeSender } from '../src/fabric/fabric'

describe('Runtime RPC client', () => {
  it('uses the business reply before a missing or failed push ACK', async () => {
    let rejectSend!: (error: Error) => void
    let requestID = ''
    const client = new RuntimeRPCClient((envelope, options) => {
      requestID = rpcRequestID(envelope)
      options?.onSent?.('old')
      return new Promise((_resolve, reject) => {
        rejectSend = reject
      })
    })
    const pending = client.request('worker_env.resolve', {}, undefined)
    client.resolve(response(requestID, { authoritative: 'reply' }))
    const result = await pending
    expect(result).toMatchObject({ vars: { authoritative: 'reply' } })
    rejectSend(new RuntimeFabricTransportError('socket_closed', 'closed after reply'))
    client.disconnected('old')
    await Bun.sleep(0)
  })

  it('rejects only requests sent on the lost connection and preserves unsent or newer requests', async () => {
    const sent: Array<{ id: string; connection?: string }> = []
    const client = new RuntimeRPCClient(async (envelope, options) => {
      const connection = sent.length === 0 ? 'old' : sent.length === 1 ? undefined : 'new'
      sent.push({ id: rpcRequestID(envelope), connection })
      if (connection) options?.onSent?.(connection)
    })
    const old = client.request('worker_env.resolve', {}, undefined).catch(error => error)
    const unsent = client.request('worker_env.resolve', {}, undefined)
    const current = client.request('worker_env.resolve', {}, undefined)
    client.disconnected('old')
    expect(await old).toMatchObject({
      code: 'socket_closed',
      message: expect.stringContaining('may already have completed')
    })
    client.resolve(response(sent[1]!.id, { unsent: 'kept' }))
    client.resolve(response(sent[2]!.id, { current: 'kept' }))
    expect(await unsent).toMatchObject({ vars: { unsent: 'kept' } })
    expect(await current).toMatchObject({ vars: { current: 'kept' } })
  })

  it('recovers an explicitly safe read after ready without replaying a write', async () => {
    let resume!: () => void
    const ready = new Promise<void>(resolve => {
      resume = resolve
    })
    const sent: string[] = []
    const client = new RuntimeRPCClient(
      async (envelope, options) => {
        options?.onSent?.(sent.length === 0 ? 'old' : 'new')
        sent.push(rpcRequestID(envelope))
      },
      { awaitReady: () => ready }
    )
    const reading = client.request('worker_env.resolve', {}, undefined, { retryOnDisconnect: true })
    client.disconnected('old')
    await Bun.sleep(0)
    expect(sent).toHaveLength(1)
    resume()
    await Bun.sleep(0)
    expect(sent).toHaveLength(2)
    client.resolve(response(sent[1]!, { recovered: 'same call' }))
    expect(await reading).toMatchObject({ vars: { recovered: 'same call' } })
    const write = client.request('files.commit', {}, undefined).catch(error => error)
    client.disconnected('new')
    expect(await write).toMatchObject({ code: 'socket_closed' })
    await Bun.sleep(0)
    expect(sent).toHaveLength(3)
  })

  it('keeps the initial deadline across safe-read reconnects', async () => {
    let attempts = 0
    const client = new RuntimeRPCClient(
      async (_envelope, options) => {
        attempts += 1
        options?.onSent?.('old')
      },
      {
        awaitReady: async signal => {
          await Bun.sleep(15)
          signal?.throwIfAborted()
        }
      }
    )
    const start = performance.now()
    const result = client
      .request('worker_env.resolve', {}, undefined, { retryOnDisconnect: true, timeoutMs: 25 })
      .catch(error => error)
    client.disconnected('old')
    await Bun.sleep(18)
    client.disconnected('old')
    expect(await result).toBeInstanceOf(RPCTimeoutError)
    expect(attempts).toBe(2)
    expect(performance.now() - start).toBeLessThan(100)
  })

  it('aborts an unsent request at its deadline so reconnect cannot send it later', async () => {
    let sendSignal: AbortSignal | undefined
    let sends = 0
    const client = new RuntimeRPCClient((_envelope, options) => {
      sendSignal = options?.signal
      return new Promise<void>((_resolve, reject) => {
        sendSignal!.addEventListener('abort', () => reject(sendSignal!.reason), { once: true })
      })
    })
    expect(
      await client.request('worker_env.resolve', {}, undefined, { timeoutMs: 5 }).catch(error => error)
    ).toMatchObject({ code: 'runtime_rpc_timeout' })
    if (!sendSignal?.aborted) sends += 1
    expect(sends).toBe(0)
  })

  it('preserves caller cancellation during reconnect', async () => {
    const cancelled = new AbortController()
    let requestID = ''
    const send: EnvelopeSender = async (envelope, options) => {
      requestID = rpcRequestID(envelope)
      options?.onSent?.('old')
    }
    const client = new RuntimeRPCClient(send, {
      awaitReady: signal =>
        new Promise((_resolve, reject) => {
          signal!.addEventListener('abort', () => reject(signal!.reason), { once: true })
        })
    })
    const pending = client
      .request('worker_env.resolve', {}, undefined, { retryOnDisconnect: true, signal: cancelled.signal })
      .catch(error => error)
    client.disconnected('old')
    await Bun.sleep(0)
    cancelled.abort(new DOMException('stop', 'AbortError'))
    expect(await pending).toMatchObject({ name: 'AbortError' })
    client.resolve(response(requestID, { late: 'ignored' }))
  })

  it('ignores a late reply after timeout and remains usable', async () => {
    const sent: Array<Parameters<ConstructorParameters<typeof RuntimeRPCClient>[0]>[0]> = []
    const client = new RuntimeRPCClient(
      async envelope => {
        sent.push(envelope)
      },
      { timeoutMs: 10 }
    )

    await expect(client.request('worker_env.resolve', {}, undefined)).rejects.toThrow(
      'RPC request timed out: worker_env.resolve'
    )
    const timedOutRequestID = rpcRequestID(sent[0]!)

    expect(() => client.resolve(response(timedOutRequestID, { stale: 'ignored' }))).not.toThrow()

    const next = client.request('worker_env.resolve', {}, undefined)
    await Promise.resolve()
    const nextRequestID = rpcRequestID(sent[1]!)
    client.resolve(response(nextRequestID, { current: 'accepted' }))

    const reply = await next
    if ('code' in reply) throw new Error(`unexpected RPC rejection: ${reply.code}`)
    expect(reply.vars).toEqual({ current: 'accepted' })
  })

  it('closes a safe read waiting for reconnect and cannot send again', async () => {
    let sends = 0
    let readyWaits = 0
    const client = new RuntimeRPCClient(
      async (_envelope, options) => {
        sends += 1
        options?.onSent?.('old')
      },
      {
        awaitReady: signal => {
          readyWaits += 1
          return new Promise((_resolve, reject) => {
            signal!.addEventListener('abort', () => reject(signal!.reason), { once: true })
          })
        }
      }
    )
    const pending = client
      .request('worker_env.resolve', {}, undefined, { retryOnDisconnect: true })
      .catch(error => error)
    client.disconnected('old')
    await Bun.sleep(0)
    client.close()
    expect(await pending).toMatchObject({ name: 'AbortError', message: 'Worker RPC client stopped' })
    await expect(client.request('worker_env.resolve', {}, undefined, { retryOnDisconnect: true })).rejects.toThrow(
      'Worker RPC client stopped'
    )
    expect(() => client.awaitReady()).toThrow('Worker RPC client stopped')
    expect(sends).toBe(1)
    expect(readyWaits).toBe(1)
    client.close()
  })
})

function rpcRequestID(envelope: Parameters<ConstructorParameters<typeof RuntimeRPCClient>[0]>[0]): string {
  if (envelope.body.case !== 'rpcRequest') throw new Error('expected rpc_request envelope')
  return envelope.body.value.requestId
}

function response(requestId: string, vars: Record<string, string>) {
  return create(RPCResponseSchema, {
    requestId,
    payload: toBinary(WorkerEnvResolveResponseSchema, create(WorkerEnvResolveResponseSchema, { vars }))
  })
}
