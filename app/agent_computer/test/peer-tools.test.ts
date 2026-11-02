import { expect, test } from 'bun:test'
import { createPeerTools } from '../src/tools/library/peer-tools'
import { buildCodexJobProjection } from '../src/core/codex-runner/job/projection'
import { jsonBytes, jsonObjectFromBytes } from '../src/fabric/envelope_proto'
import type { RPCRequester, RPCCallOptions } from '../src/lanes/rpc_lane'
import type { JobTurnRef } from '../src/lanes/session_lane'

test('Job peer tools preserve the fenced turn and idempotent call identity through the real projection', async () => {
  const turn: JobTurnRef = {
    session: { session_id: 'job:1000' },
    job_id: 1000,
    attempt: 2,
    signal_id: '00000000-0000-0000-0000-000000000001'
  }
  const calls: unknown[] = []
  const rpc = (async (method: string, payload: unknown, scope: unknown, options?: RPCCallOptions) => {
    const request = payload as { name: string; operation: string; argumentsJson?: Uint8Array; paramsJson?: Uint8Array }
    calls.push({
      method,
      name: request.name ?? request.operation,
      args: jsonObjectFromBytes((request.argumentsJson ?? request.paramsJson)!, 'args'),
      scope
    })
    expect(options?.retryOnDisconnect).toBe(true)
    return {
      bodyJson: jsonBytes(
        method === 'tools.read'
          ? { output: 'Earlier review', details: { next_cursor: null } }
          : { result: { output: 'target_missing_page_access', is_error: true } }
      )
    }
  }) as unknown as RPCRequester
  const tools = createPeerTools({
    turn,
    rpc,
    requestContext: {
      peer_tools: [
        { name: 'send_to_agent', description: 'Delegate', parameters: { type: 'object' }, read_only: false },
        {
          name: 'recall_related_context',
          description: 'Read prior work',
          parameters: { type: 'object' },
          read_only: true
        }
      ]
    }
  })
  const projection = buildCodexJobProjection({ tools })
  const call = (name: string, args: Record<string, string>) =>
    projection.handleToolCall(
      {
        threadId: 'thread',
        turnId: 'turn',
        callId: 'stable-call',
        namespace: null,
        tool: name,
        arguments: args
      },
      new AbortController().signal
    )
  expect(await call('send_to_agent', { target_agent_uid: 'legal', message: 'Review' })).toEqual({
    contentItems: [{ type: 'inputText', text: 'target_missing_page_access' }],
    success: false
  })
  expect(await call('recall_related_context', { ref_id: 'exchange' })).toEqual({
    contentItems: [{ type: 'inputText', text: 'Earlier review' }],
    success: true
  })
  expect(calls).toEqual([
    {
      method: 'pod.write',
      name: 'chat.send_to_agent',
      args: { target_agent_uid: 'legal', message: 'Review', call_id: 'stable-call' },
      scope: { jobTurn: turn }
    },
    { method: 'tools.read', name: 'recall_related_context', args: { ref_id: 'exchange' }, scope: { jobTurn: turn } }
  ])
  expect(createPeerTools({ turn, rpc })).toEqual([])
})
