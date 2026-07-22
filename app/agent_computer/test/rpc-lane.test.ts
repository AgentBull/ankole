import { create, toBinary } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { RPCResponseSchema } from '../src/fabric/envelope_proto'
import { WorkerEnvResolveResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { rpcMethods, RuntimeRPCClient } from '../src/lanes/rpc_lane'

describe('Runtime RPC client', () => {
  it('ignores a late reply after timeout and remains usable', async () => {
    const sent: Array<Parameters<ConstructorParameters<typeof RuntimeRPCClient>[0]>[0]> = []
    const client = new RuntimeRPCClient(
      async envelope => {
        sent.push(envelope)
      },
      { timeoutMs: 10 }
    )

    await expect(client.request(rpcMethods.workerEnvResolve, {}, { agentUid: 'agent-1' })).rejects.toThrow(
      'RPC request timed out: worker_env.resolve'
    )
    const timedOutRequestID = rpcRequestID(sent[0]!)

    expect(() => client.resolve(response(timedOutRequestID, { stale: 'ignored' }))).not.toThrow()

    const next = client.request(rpcMethods.workerEnvResolve, {}, { agentUid: 'agent-1' })
    await Promise.resolve()
    const nextRequestID = rpcRequestID(sent[1]!)
    client.resolve(response(nextRequestID, { current: 'accepted' }))

    const reply = await next
    if ('code' in reply) throw new Error(`unexpected RPC rejection: ${reply.code}`)
    expect(reply.vars).toEqual({ current: 'accepted' })
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
