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
  it('defaults the foreground observation window to 30 seconds and enforces 10-150 seconds', () => {
    const tool = createSendMessageToBackgroundJobTool(toolOptions(async () => sendResponse()))
    const parsed = tool.schema.parse({ job_id: jobID, message: 'Use plain language.' })

    expect(parsed).toEqual({
      job_id: jobID,
      message: 'Use plain language.',
      wait_reply: true,
      wait_timeout_ms: 30_000
    })
    expect(tool.schema.safeParse({ job_id: jobID, message: 'x', wait_timeout_ms: 9_999 }).success).toBe(false)
    expect(tool.schema.safeParse({ job_id: jobID, message: 'x', wait_timeout_ms: 10_000 }).success).toBe(true)
    expect(tool.schema.safeParse({ job_id: jobID, message: 'x', wait_timeout_ms: 150_000 }).success).toBe(true)
    expect(tool.schema.safeParse({ job_id: jobID, message: 'x', wait_timeout_ms: 150_001 }).success).toBe(false)
    expect(tool.schema.safeParse({ job_id: jobID, message: 'x', action: 'steer' }).success).toBe(false)
    expect(tool.schema.safeParse({ job_id: jobID, message: 'x', answers: {} }).success).toBe(false)
    expect(tool.schema.safeParse({ job_id: jobID, message: '' }).success).toBe(false)
    expect(tool.schema.safeParse({ job_id: 999, message: 'x' }).success).toBe(false)
    expect(tool.schema.safeParse({ job_id: '019f0000-0000-7000-8000-000000000001', message: 'x' }).success).toBe(false)

    expect(tool.describeActivity(parsed)).toEqual({
      key: 'signals_gateway.reply.activity.background_job_wait',
      bindings: { job: jobID, seconds: 30 }
    })
    expect(tool.describeCompletedActivity?.(parsed, {} as never)).toEqual({
      key: 'signals_gateway.reply.activity.background_job_replied'
    })

    const synchronous = tool.schema.parse({ job_id: jobID, message: 'Use plain language.', wait_reply: true })
    expect(tool.describeActivity(synchronous)).toEqual({
      key: 'signals_gateway.reply.activity.background_job_wait',
      bindings: { job: jobID, seconds: 30 }
    })
    expect(tool.describeCompletedActivity?.(synchronous, {} as never)).toEqual({
      key: 'signals_gateway.reply.activity.background_job_replied'
    })

    const asynchronous = tool.schema.parse({ job_id: jobID, message: 'Use plain language.', wait_reply: false })
    expect(tool.describeActivity(asynchronous)).toEqual({ key: 'signals_gateway.reply.activity.background_job_send' })
    expect(tool.describeCompletedActivity?.(asynchronous, {} as never)).toEqual({
      key: 'signals_gateway.reply.activity.background_job_sent'
    })
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
      wait_reply: false,
      wait_timeout_ms: 30_000
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
      wait_reply: true,
      wait_timeout_ms: 30_000
    })

    expect(methods).toEqual([rpcMethods.backgroundAgentJobMessageSend, rpcMethods.backgroundAgentJobMessageResult])
    expect(result.details).toEqual({
      job_id: jobID,
      status: 'waiting_on_user',
      last_turn_trajectory: trajectory(),
      earlier_trajectory_omitted: true,
      continues_running: false,
      reply_ready: true,
      wait_outcome: 'reply_ready'
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
      tool.execute(
        'call-send',
        { job_id: jobID, message: 'Use plain language.', wait_reply: true, wait_timeout_ms: 30_000 },
        controller.signal
      )
    ).rejects.toThrow('parent Turn canceled')
  })

  it('ends only the foreground observation when its deadline expires', async () => {
    let nowCalls = 0
    const tool = createSendMessageToBackgroundJobTool({
      ...toolOptions(async method => {
        if (method === rpcMethods.backgroundAgentJobMessageSend) return sendResponse()
        return new Promise(() => undefined)
      }),
      now: () => (nowCalls++ === 0 ? 0 : 30_000)
    })

    const result = await tool.execute('call-send', {
      job_id: jobID,
      message: 'Use plain language.',
      wait_reply: true,
      wait_timeout_ms: 30_000
    })

    expect(result.details).toEqual({
      job_id: jobID,
      status: 'running',
      continues_running: true,
      reply_ready: false,
      wait_outcome: 'timed_out'
    })
    expect(result.content[0]).toEqual({
      type: 'text',
      text: [
        `Stopped waiting for background job ${jobID} because the foreground observation window expired.`,
        'Current job status: running.',
        'The message was already delivered; do not resend it.',
        'The job continues to run in the background.'
      ].join('\n')
    })
    expect(
      tool.describeCompletedActivity?.(tool.schema.parse({ job_id: jobID, message: 'x' }), result.details)
    ).toEqual({ key: 'signals_gateway.reply.activity.background_job_async' })
  })

  it('releases the wait when steering arrives without resending the job message', async () => {
    let releaseSteering: (() => void) | undefined
    const methods: unknown[] = []
    const tool = createSendMessageToBackgroundJobTool({
      ...toolOptions(async method => {
        methods.push(method)
        if (method === rpcMethods.backgroundAgentJobMessageSend) return sendResponse()
        return new Promise(() => undefined)
      }),
      waitForSteering: () =>
        new Promise<void>(resolve => {
          releaseSteering = resolve
        })
    })

    const waiting = tool.execute('call-send', {
      job_id: jobID,
      message: 'Use plain language.',
      wait_reply: true,
      wait_timeout_ms: 150_000
    })
    while (!releaseSteering) await Promise.resolve()
    releaseSteering()
    const result = await waiting

    expect(methods).toEqual([rpcMethods.backgroundAgentJobMessageSend, rpcMethods.backgroundAgentJobMessageResult])
    expect(result.details).toEqual({
      job_id: jobID,
      status: 'running',
      continues_running: true,
      reply_ready: false,
      wait_outcome: 'steered'
    })
    expect(result.content[0]?.type === 'text' ? result.content[0].text : '').toContain(
      'The message was already delivered; do not resend it.'
    )
    expect(
      tool.describeCompletedActivity?.(tool.schema.parse({ job_id: jobID, message: 'x' }), result.details)
    ).toEqual({ key: 'signals_gateway.reply.activity.background_job_steered' })
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
    metadata: { redacted: true, content_truncated: true },
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
    metadata: { redacted: true, content_truncated: true },
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
