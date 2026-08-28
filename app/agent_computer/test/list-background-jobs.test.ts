import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import {
  BackgroundAgentJobListResponseSchema,
  BackgroundAgentJobSummarySchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import { createListBackgroundJobsTool } from '../src/tools/background-agent-job/list-background-jobs'
import { turnStartForTest } from './support/llm'

describe('@ankole/agent-computer list background jobs tool', () => {
  it('accepts only the status group and turn-local page reference', () => {
    const tool = createListBackgroundJobsTool({
      turnStart: turnStartForTest(),
      rpc: (async () => listResponse()) as RPCRequester
    })

    expect(tool.schema.safeParse({}).success).toBe(true)
    expect(tool.schema.safeParse({ status: 'live' }).success).toBe(true)
    expect(tool.schema.safeParse({ status: 'stop', page: 'page_1' }).success).toBe(true)
    expect(tool.schema.safeParse({ status: 'failed' }).success).toBe(false)
    expect(tool.schema.safeParse({ cursor: 'opaque' }).success).toBe(false)
    expect(tool.schema.safeParse({ page: 'opaque' }).success).toBe(false)
    expect(tool.schema.safeParse({ action: 'list' }).success).toBe(false)
    expect(tool.schema.safeParse({ agent_id: 'agent-1' }).success).toBe(false)
  })

  it('defaults to live and returns only the public list fields', async () => {
    const requests: Array<Record<string, unknown>> = []
    const tool = createListBackgroundJobsTool({
      turnStart: turnStartForTest(),
      rpc: (async (method: unknown, payload: unknown) => {
        expect(method).toBe(rpcMethods.backgroundAgentJobList)
        requests.push(payload as Record<string, unknown>)
        return listResponse()
      }) as RPCRequester
    })

    expect(tool.executionMode).toBe('parallel')
    expect(tool.isReadOnly).toBe(true)
    expect(tool.isDestructive).toBe(false)

    const result = await tool.execute('call-list', {}, new AbortController().signal)

    expect(requests).toEqual([{ status: 'live', cursor: '' }])
    expect(result.details).toEqual({
      jobs: [
        {
          job_id: 1000,
          title: 'Research',
          status: 'waiting_on_user'
        }
      ],
      next_page: 'page_1'
    })
    expect(JSON.stringify(result.details)).not.toContain(rawCursor)
    expect(JSON.parse(result.content[0]!.type === 'text' ? result.content[0]!.text : '')).toEqual(result.details)
  })

  it('resolves a returned page reference to the internal cursor', async () => {
    const requests: Array<Record<string, unknown>> = []
    let callCount = 0
    const tool = createListBackgroundJobsTool({
      turnStart: turnStartForTest(),
      rpc: (async (_method: unknown, payload: unknown) => {
        requests.push(payload as Record<string, unknown>)
        callCount += 1
        return callCount === 1 ? listResponse() : create(BackgroundAgentJobListResponseSchema)
      }) as RPCRequester
    })

    await expect(
      tool.execute('call-list-unknown', { status: 'stop', page: 'page_1' }, new AbortController().signal)
    ).rejects.toThrow('unknown background agent job page page_1; use next_page from this turn')
    await tool.execute('call-list-first', { status: 'stop' }, new AbortController().signal)
    const result = await tool.execute('call-list', { status: 'stop', page: 'page_1' }, new AbortController().signal)

    expect(requests).toEqual([
      { status: 'stop', cursor: '' },
      { status: 'stop', cursor: rawCursor }
    ])
    expect(result.details).toEqual({ jobs: [], next_page: null })
  })
})

function listResponse() {
  return create(BackgroundAgentJobListResponseSchema, {
    jobs: [
      create(BackgroundAgentJobSummarySchema, {
        jobId: '1000',
        title: 'Research',
        status: 'waiting_on_user'
      })
    ],
    nextCursor: rawCursor
  })
}

const rawCursor = '019f0000-0000-7000-8000-000000000099'
