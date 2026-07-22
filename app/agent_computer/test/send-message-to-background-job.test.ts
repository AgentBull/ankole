import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { jsonBytes } from '../src/fabric/envelope_proto'
import {
  BackgroundAgentJobMessageResultResponseSchema,
  BackgroundAgentJobMessageSendResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import { createSendMessageToBackgroundJobTool } from '../src/tools/background-agent-job/send-message-to-background-job'
import { turnStartForTest } from './support/llm'

const jobID = 1000
const commandEventID = '019f0000-0000-7000-8000-000000000002'
const lifecycleEventID = '019f0000-0000-7000-8000-000000000003'

describe('@ankole/agent-computer send_message_to_background_job tool', () => {
  it('accepts only job_id, message, and wait_reply with waiting enabled by default', () => {
    const tool = createSendMessageToBackgroundJobTool(toolOptions(async () => sendResponse()))
    const parsed = tool.schema.parse({ job_id: jobID, message: 'Use plain language.' })

    expect(parsed).toEqual({ job_id: jobID, message: 'Use plain language.', wait_reply: true })
    expect(tool.schema.safeParse({ job_id: jobID, message: 'x', action: 'steer' }).success).toBe(false)
    expect(tool.schema.safeParse({ job_id: jobID, message: 'x', answers: {} }).success).toBe(false)
    expect(tool.schema.safeParse({ job_id: jobID, message: '' }).success).toBe(false)
    expect(tool.schema.safeParse({ job_id: 999, message: 'x' }).success).toBe(false)
    expect(tool.schema.safeParse({ job_id: '019f0000-0000-7000-8000-000000000001', message: 'x' }).success).toBe(false)
  })

  it('returns immediately after send when wait_reply is false', async () => {
    const calls: Array<{ method: unknown; payload: unknown }> = []
    const tool = createSendMessageToBackgroundJobTool(
      toolOptions(async (method, payload) => {
        calls.push({ method, payload })
        return sendResponse()
      })
    )

    const result = await tool.execute('call-send', {
      job_id: jobID,
      message: 'Use plain language.',
      wait_reply: false
    })

    expect(calls).toEqual([
      {
        method: rpcMethods.backgroundAgentJobMessageSend,
        payload: { jobId: String(jobID), message: 'Use plain language.', sourceToolCallId: 'call-send' }
      }
    ])
    expect(result.details).toEqual({ job_id: jobID, status: 'running' })
    expect(result.completeActorEventIDs).toBeUndefined()
    expect(result.content).toEqual([
      {
        type: 'text',
        text: `Message sent to background job ${jobID}. Current job status: running.`
      }
    ])
  })

  it('returns the exact causal Turn and hands off an eligible lifecycle event', async () => {
    const methods: unknown[] = []
    const tool = createSendMessageToBackgroundJobTool(
      toolOptions(async method => {
        methods.push(method)
        return methods.length === 1 ? sendResponse() : readyResponse()
      })
    )

    const result = await tool.execute('call-send', {
      job_id: jobID,
      message: 'Operators',
      wait_reply: true
    })

    expect(methods).toEqual([rpcMethods.backgroundAgentJobMessageSend, rpcMethods.backgroundAgentJobMessageResult])
    expect(result.details).toEqual({
      job_id: jobID,
      status: 'waiting_on_user',
      last_turn_trajectory: trajectory(),
      earlier_trajectory_omitted: true,
      continues_running: false
    })
    expect(result.completeActorEventIDs).toEqual([lifecycleEventID])
    expect(result.content[0]).toEqual({
      type: 'text',
      text: `Last turn trajectory:\n${JSON.stringify(trajectory())}\nEarlier trajectory items were omitted.`
    })
    expect(JSON.stringify(result.details)).not.toContain(storedToolCallID)
  })

  it('stops polling when the parent Turn is canceled without completing an event', async () => {
    const controller = new AbortController()
    let calls = 0
    const tool = createSendMessageToBackgroundJobTool(
      toolOptions(async () => {
        calls += 1
        if (calls === 1) return sendResponse()
        controller.abort(new Error('parent Turn canceled'))
        return create(BackgroundAgentJobMessageResultResponseSchema, {
          jobId: String(jobID),
          status: 'running',
          ready: false
        })
      })
    )

    await expect(
      tool.execute('call-send', { job_id: jobID, message: 'Use plain language.', wait_reply: true }, controller.signal)
    ).rejects.toThrow('parent Turn canceled')
  })
})

function toolOptions(rpc: (...args: any[]) => Promise<any>) {
  return {
    turnStart: turnStartForTest(),
    rpc: rpc as RPCRequester
  }
}

function sendResponse() {
  return create(BackgroundAgentJobMessageSendResponseSchema, {
    jobId: String(jobID),
    status: 'running',
    commandEventId: commandEventID
  })
}

function readyResponse() {
  return create(BackgroundAgentJobMessageResultResponseSchema, {
    jobId: String(jobID),
    status: 'waiting_on_user',
    ready: true,
    lastTurnTrajectoryJson: jsonBytes(storedTrajectory()),
    earlierTrajectoryOmitted: true,
    lifecycleActorEventId: lifecycleEventID
  })
}

function trajectory() {
  return {
    format: 'ankole_chatml' as const,
    version: 1 as const,
    messages: [
      { role: 'user', content: 'Operators' },
      {
        role: 'assistant',
        content: '',
        tool_calls: [
          {
            id: 'call_1',
            type: 'function',
            function: { name: 'lookup', arguments: '{"topic":"audience"}' }
          }
        ]
      },
      { role: 'tool', tool_call_id: 'call_1', name: 'lookup', content: 'Executives' },
      { role: 'assistant', content: 'Which audience?' }
    ]
  }
}

function storedTrajectory() {
  return {
    format: 'ankole_chatml' as const,
    version: 1 as const,
    messages: [
      { id: '019f0000-0000-7000-8000-000000000010', role: 'user', content: 'Operators' },
      {
        id: '019f0000-0000-7000-8000-000000000011',
        role: 'assistant',
        content: '',
        tool_calls: [
          {
            id: storedToolCallID,
            type: 'function',
            function: { name: 'lookup', arguments: '{"topic":"audience"}' }
          }
        ]
      },
      {
        id: '019f0000-0000-7000-8000-000000000013',
        role: 'tool',
        tool_call_id: storedToolCallID,
        name: 'lookup',
        content: 'Executives'
      },
      { id: '019f0000-0000-7000-8000-000000000014', role: 'assistant', content: 'Which audience?' }
    ]
  }
}

const storedToolCallID = '019f0000-0000-7000-8000-000000000012'
