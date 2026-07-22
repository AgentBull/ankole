import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { BackgroundAgentJobStopResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import { createStopBackgroundJobTool } from '../src/tools/background-agent-job/stop-background-job'
import { turnStartForTest } from './support/llm'

const jobID = 1000

describe('@ankole/agent-computer stop_background_job tool', () => {
  it('accepts only job_id and returns only job_id and status', async () => {
    const calls: Array<{ method: unknown; payload: unknown }> = []
    const tool = createStopBackgroundJobTool({
      turnStart: turnStartForTest(),
      rpc: (async (method: unknown, payload: unknown) => {
        calls.push({ method, payload })
        return create(BackgroundAgentJobStopResponseSchema, { jobId: String(jobID), status: 'stopped' })
      }) as RPCRequester
    })

    expect(tool.schema.safeParse({ job_id: jobID }).success).toBe(true)
    expect(tool.schema.safeParse({ job_id: jobID, reason: 'no longer needed' }).success).toBe(false)
    expect(tool.schema.safeParse({ action: 'stop', job_id: jobID }).success).toBe(false)

    const result = await tool.execute('call-stop', { job_id: jobID })

    expect(calls).toEqual([{ method: rpcMethods.backgroundAgentJobStop, payload: { jobId: String(jobID) } }])
    expect(result.details).toEqual({ job_id: jobID, status: 'stopped' })
    expect(JSON.parse(result.content[0]!.type === 'text' ? result.content[0]!.text : '')).toEqual(result.details)
  })
})
