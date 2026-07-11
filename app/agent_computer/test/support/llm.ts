import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { z } from 'zod'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { createModel } from '../../src/core/llm'

type CreateModelOptions = Parameters<typeof createModel>[0]
type TestResponseWebSocket = ReturnType<
  NonNullable<NonNullable<CreateModelOptions['responseWebSocket']>['createWebSocket']>
>

export function parallelReadTool(name: string, events: string[], delayMs: number, text: string) {
  return {
    name,
    description: `Read ${name}`,
    schema: z.object({}),
    executionMode: 'parallel' as const,
    isReadOnly: true,
    isDestructive: false,
    execute: async () => {
      events.push(`${name}:start`)
      await sleep(delayMs)
      events.push(`${name}:end`)
      return { content: [{ type: 'text' as const, text }], details: {} }
    }
  }
}

export function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

export function turnStartForTest() {
  return {
    turn: {
      actor: { agent_uid: 'agent-1', session_id: 'session-1' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      actor_event_id: '00000000-0000-0000-0000-000000000001',
      revision: 0
    },
    actor_event: {
      actor_event_id: '00000000-0000-0000-0000-000000000001',
      queue_sequence: 1,
      type: 'check_back_later.wakeup',
      source_event_id: 'schedule-1',
      payload_json: {}
    },
    model_ref: { profile: 'primary', provider_id: 'openrouter', model: 'z-ai/glm-5.2' },
    request_context: { ai_agent: { max_iterations: 90 } }
  }
}

export async function withImageWorkspace(
  run: (workspaceRoot: string, imagePath: string) => Promise<void>
): Promise<void> {
  const workspaceRoot = mkdtempSync(join(tmpdir(), 'ankole-agent-computer-vision-'))
  const relativePath = join('user-files', 'inbox', 'lark', 'photo.png')
  const filePath = join(workspaceRoot, relativePath)
  mkdirSync(join(workspaceRoot, 'user-files', 'inbox', 'lark'), { recursive: true })
  writeFileSync(
    filePath,
    Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
      'base64'
    )
  )

  try {
    await run(workspaceRoot, `/workspace/${relativePath.replaceAll('\\', '/')}`)
  } finally {
    rmSync(workspaceRoot, { recursive: true, force: true })
  }
}

export function imageActorEventPayload(imagePath: string) {
  return {
    data: {
      entry: {
        text: 'Please inspect this.',
        attachments: [
          {
            name: 'photo.png',
            resource_type: 'image',
            agent_computer_path: imagePath
          }
        ]
      }
    }
  }
}

export function modelRefForTest(inputModalities: string[]) {
  return {
    profile: 'primary',
    provider_id: 'openai-main',
    model: 'test-model',
    provider_kind: 'openai',
    input_modalities: inputModalities
  }
}

export function fallbackModelForTest(summary: string, bodies: JSONObject[]) {
  return createModel({
    apiKey: 'unused',
    baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
    selector: 'vision_fallback',
    fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      const request = input instanceof Request ? input : new Request(input, init)
      bodies.push(JSON.parse(await request.text()) as JSONObject)

      return new Response(
        JSON.stringify({
          id: 'resp_fallback_summary',
          object: 'response',
          status: 'completed',
          output: [
            {
              type: 'message',
              role: 'assistant',
              content: [{ type: 'output_text', text: summary }]
            }
          ]
        }),
        { status: 200, headers: { 'content-type': 'application/json' } }
      )
    }) as unknown as typeof fetch
  })
}

export function toolResultsRecordedFrame(id: string): JSONObject {
  return {
    type: 'response.tool_results.recorded',
    response_id: id,
    response: {
      id,
      status: 'completed',
      output: []
    }
  }
}

export function fakeResponseSocket(
  init: { headers: Record<string, string> },
  onSend: (data: string, socket: FakeResponseSocket) => JSONObject[]
): TestResponseWebSocket {
  const socket = new FakeResponseSocket(init, onSend)
  queueMicrotask(() => socket.emitOpen())
  return testResponseSocket(socket)
}

export function testResponseSocket(socket: FakeResponseSocket): TestResponseWebSocket {
  return socket as unknown as TestResponseWebSocket
}

export class FakeResponseSocket {
  readyState = 0
  closeCount = 0
  private listeners = new Map<string, Array<{ listener: (event: unknown) => void; once: boolean }>>()

  constructor(
    readonly init: { headers: Record<string, string> },
    private readonly onSend: (data: string, socket: FakeResponseSocket) => JSONObject[]
  ) {}

  send(data: string): void {
    if (!authorizationHeader(this.init.headers).startsWith('Bearer ')) {
      throw new Error('missing authorization header')
    }

    for (const frame of this.onSend(data, this)) {
      this.emitMessage(frame)
    }
  }

  close(): void {
    this.closeCount += 1
    this.readyState = 3
  }

  addEventListener(type: string, listener: (event: unknown) => void, options?: { once?: boolean }): void {
    const listeners = this.listeners.get(type) ?? []
    listeners.push({ listener, once: options?.once ?? false })
    this.listeners.set(type, listeners)
  }

  removeEventListener(type: string, listener: (event: unknown) => void): void {
    const listeners = this.listeners.get(type) ?? []
    this.listeners.set(
      type,
      listeners.filter(entry => entry.listener !== listener)
    )
  }

  emitOpen(): void {
    this.readyState = 1
    this.emit('open', {})
  }

  emitClose(reason = ''): void {
    this.readyState = 3
    this.emit('close', { reason })
  }

  emitError(): void {
    this.emit('error', {})
  }

  private emitMessage(frame: JSONObject): void {
    this.emit('message', { data: JSON.stringify(frame) })
  }

  private emit(type: string, event: unknown): void {
    const listeners = this.listeners.get(type) ?? []
    this.listeners.set(
      type,
      listeners.filter(entry => {
        entry.listener(event)
        return !entry.once
      })
    )
  }
}

function authorizationHeader(headers: Record<string, string>): string {
  return headers.authorization ?? headers.Authorization ?? ''
}
