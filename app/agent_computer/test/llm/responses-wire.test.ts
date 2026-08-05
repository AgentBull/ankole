import { describe, expect, it } from 'bun:test'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { z } from 'zod'
import { runAgentLoop } from '../../src/core/agent-loop'
import { callModel, createModel } from '../../src/core/llm'
import { parseOutputItems } from '../../src/core/llm/parse'
import { classifyLLMError, isLocallyRetryableLLMError } from '../../src/core/llm-error-classifier'
import {
  estimateResponseRequestTokens,
  responseEventStaleTimeoutMs,
  responseFrameRefreshesStaleDeadline
} from '../../src/core/llm/session'
import { buildResponseCreateParams, toResponseInput } from '../../src/core/llm/wire'

import { fakeResponseSocket } from '../support/llm'

describe('@ankole/agent-computer llm helpers: Responses HTTP and WebSocket wire shape', () => {
  it('uses a 300-second post-output stale window only above 100k estimated request tokens', () => {
    expect(responseEventStaleTimeoutMs(100_000)).toBe(180_000)
    expect(responseEventStaleTimeoutMs(100_001)).toBe(300_000)

    const estimated = estimateResponseRequestTokens({
      model: 'primary',
      input: '中'.repeat(100_001)
    })
    expect(estimated).toBeGreaterThan(100_000)
    expect(responseEventStaleTimeoutMs(estimated)).toBe(300_000)
  })

  it('does not arm the post-output stale window from admission-only response frames', () => {
    for (const frameType of ['response.created', 'response.queued', 'response.in_progress']) {
      expect(responseFrameRefreshesStaleDeadline(frameType, false)).toBeFalse()
      expect(responseFrameRefreshesStaleDeadline(frameType, true)).toBeTrue()
    }

    expect(responseFrameRefreshesStaleDeadline('response.output_item.added', false)).toBeTrue()
    expect(responseFrameRefreshesStaleDeadline('response.output_text.delta', false)).toBeTrue()
    expect(responseFrameRefreshesStaleDeadline('error', false)).toBeTrue()
    expect(responseFrameRefreshesStaleDeadline('open', false)).toBeFalse()
  })

  it('keys the reusable prompt prefix independently of dynamic messages and tool insertion order', () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary'
    })
    const first = buildResponseCreateParams(model, {
      instructions: 'stable instructions',
      messages: [{ role: 'user', content: 'first dynamic message' }],
      tools: {
        zebra: {
          name: 'zebra',
          description: 'Zebra tool',
          parameters: z.object({})
        },
        alpha: {
          name: 'alpha',
          description: 'Alpha tool',
          parameters: z.object({ q: z.string() })
        }
      }
    })
    const second = buildResponseCreateParams(model, {
      instructions: 'stable instructions',
      messages: [{ role: 'user', content: 'different dynamic message' }],
      tools: {
        alpha: {
          name: 'alpha',
          description: 'Alpha tool',
          parameters: z.object({ q: z.string() })
        },
        zebra: {
          name: 'zebra',
          description: 'Zebra tool',
          parameters: z.object({})
        }
      }
    })

    expect(first.prompt_cache_key).toMatch(/^ankole_[0-9a-f]{32}$/)
    expect(second.prompt_cache_key).toBe(first.prompt_cache_key)
    expect(first.tools?.map(tool => ('name' in tool ? tool.name : undefined))).toEqual(['alpha', 'zebra'])
    expect(second.tools?.map(tool => ('name' in tool ? tool.name : undefined))).toEqual(['alpha', 'zebra'])
    expect(JSON.stringify({ instructions: first.instructions, tools: first.tools })).toBe(
      JSON.stringify({
        instructions: second.instructions,
        tools: second.tools
      })
    )

    const longStablePrefix = 'stable policy '.repeat(400)
    const firstSuffix = buildResponseCreateParams(model, {
      instructions: `${longStablePrefix}runtime suffix one`,
      messages: [{ role: 'user', content: 'first dynamic message' }],
      tools: {
        zebra: {
          name: 'zebra',
          description: 'Zebra tool',
          parameters: z.object({})
        },
        alpha: {
          name: 'alpha',
          description: 'Alpha tool',
          parameters: z.object({ q: z.string() })
        }
      }
    })
    const secondSuffix = buildResponseCreateParams(model, {
      instructions: `${longStablePrefix}runtime suffix two`,
      messages: [{ role: 'user', content: 'different dynamic message' }],
      tools: {
        alpha: {
          name: 'alpha',
          description: 'Alpha tool',
          parameters: z.object({ q: z.string() })
        },
        zebra: {
          name: 'zebra',
          description: 'Zebra tool',
          parameters: z.object({})
        }
      }
    })

    expect(secondSuffix.prompt_cache_key).toBe(firstSuffix.prompt_cache_key)
    expect(
      buildResponseCreateParams(model, {
        instructions: 'changed instructions',
        messages: [{ role: 'user', content: 'first dynamic message' }],
        tools: {
          zebra: {
            name: 'zebra',
            description: 'Zebra tool',
            parameters: z.object({})
          },
          alpha: {
            name: 'alpha',
            description: 'Alpha tool',
            parameters: z.object({ q: z.string() })
          }
        }
      }).prompt_cache_key
    ).not.toBe(first.prompt_cache_key)
    expect(
      buildResponseCreateParams(model, {
        messages: [{ role: 'user', content: 'no reusable prefix' }]
      }).prompt_cache_key
    ).toBeUndefined()
  })

  it('merges the hosted image tool with function tools and includes it in the prompt cache prefix', () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary'
    })
    const baseOptions = {
      instructions: 'stable instructions',
      messages: [{ role: 'user' as const, content: 'draw and annotate' }],
      tools: {
        annotate: {
          name: 'annotate',
          description: 'Annotate a result',
          parameters: z.object({ label: z.string() })
        }
      }
    }

    const withoutHosted = buildResponseCreateParams(model, baseOptions)
    const withHosted = buildResponseCreateParams(model, {
      ...baseOptions,
      hostedTools: [{ type: 'image_generation' }]
    })
    const hostedOnly = buildResponseCreateParams(model, {
      messages: [{ role: 'user', content: 'draw' }],
      hostedTools: [{ type: 'image_generation' }]
    })

    expect(withHosted.tools).toEqual([
      expect.objectContaining({ type: 'function', name: 'annotate' }),
      { type: 'image_generation' }
    ])
    expect(hostedOnly.tools).toEqual([{ type: 'image_generation' }])
    expect(withHosted.prompt_cache_key).not.toBe(withoutHosted.prompt_cache_key)
  })

  it('declares deferred namespace tools, hosted Tool Search, and PTC in the official wire shape', () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary'
    })

    const request = buildResponseCreateParams(model, {
      messages: [{ role: 'user', content: 'query finance data' }],
      programmaticToolCalling: true,
      tools: {
        stockPrice: {
          name: 'stock_price',
          description: 'Query one stock price.',
          parameters: z.record(z.string(), z.unknown()),
          jsonSchema: {
            type: 'object',
            properties: {
              symbol: { type: 'string' },
              window_days: { type: 'number', minimum: 1, maximum: 365 }
            },
            required: ['symbol', 'window_days'],
            additionalProperties: false
          },
          namespace: 'mcp__finance',
          namespaceDescription: 'Financial data tools.',
          deferLoading: true,
          toolSearchText:
            'mcp__finance__stock_price stock_price stock-price finance Stock Price Financial data tools symbol',
          allowedCallers: ['direct', 'programmatic']
        }
      }
    })

    expect(request.tools as unknown).toEqual([
      {
        type: 'namespace',
        name: 'mcp__finance',
        description: 'Financial data tools.',
        tools: [
          {
            type: 'function',
            name: 'stock_price',
            description: 'Query one stock price.',
            parameters: {
              type: 'object',
              properties: {
                symbol: { type: 'string' },
                window_days: { type: 'number', minimum: 1, maximum: 365 }
              },
              required: ['symbol', 'window_days'],
              additionalProperties: false
            },
            strict: false,
            defer_loading: true,
            __ankole_search_text:
              'mcp__finance__stock_price stock_price stock-price finance Stock Price Financial data tools symbol',
            allowed_callers: ['direct', 'programmatic']
          }
        ]
      },
      { type: 'tool_search', execution: 'server' },
      { type: 'programmatic_tool_calling' }
    ])
  })

  it('declares a freeform custom tool with its grammar unchanged', () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary'
    })
    const definition = 'start: "*** Begin Patch" LF "*** End Patch" LF?\n%import common.LF'

    const request = buildResponseCreateParams(model, {
      messages: [{ role: 'user', content: 'edit one file' }],
      tools: {
        applyPatch: {
          name: 'apply_patch',
          description: 'Apply one patch.',
          parameters: z.string(),
          inputFormat: {
            type: 'grammar',
            syntax: 'lark',
            definition
          },
          allowedCallers: ['direct']
        }
      }
    })

    expect(request.tools).toEqual([
      {
        type: 'custom',
        name: 'apply_patch',
        description: 'Apply one patch.',
        format: {
          type: 'grammar',
          syntax: 'lark',
          definition
        },
        allowed_callers: ['direct']
      }
    ])
  })

  it('round-trips namespace and program caller on function calls and outputs', () => {
    const caller = { type: 'program' as const, caller_id: 'prog_1' }
    const input = toResponseInput([
      {
        role: 'assistant',
        content: [],
        toolCalls: [
          {
            id: 'call_1',
            type: 'function',
            namespace: 'mcp__finance',
            name: 'stock_price',
            arguments: '{"symbol":"600519"}',
            caller
          }
        ]
      },
      {
        role: 'tool',
        toolCallID: 'call_1',
        result: '{"price":1700}',
        caller
      }
    ])

    expect(input).toEqual([
      {
        type: 'function_call',
        call_id: 'call_1',
        namespace: 'mcp__finance',
        name: 'stock_price',
        arguments: '{"symbol":"600519"}',
        caller
      },
      {
        type: 'function_call_output',
        call_id: 'call_1',
        output: '{"price":1700}',
        caller
      }
    ])
  })

  it('keeps direct and program-scoped calls distinct when their raw call ids match', () => {
    const calls = [
      {
        type: 'function_call',
        call_id: 'same',
        name: 'direct_lookup',
        arguments: '{}',
        status: 'completed'
      },
      {
        type: 'function_call',
        call_id: 'same',
        name: 'nested_lookup',
        arguments: '{}',
        status: 'completed',
        caller: { type: 'program', caller_id: 'program_1' }
      }
    ]

    const result = parseOutputItems(calls as never, 'gpt-5.6', undefined, undefined, '', undefined, calls as never)

    expect(result.message.toolCalls).toEqual([
      expect.objectContaining({ id: 'same', name: 'direct_lookup' }),
      expect.objectContaining({
        id: 'same',
        name: 'nested_lookup',
        caller: { type: 'program', caller_id: 'program_1' }
      })
    ])
  })

  it('uses changed terminal arguments instead of the same caller-scoped streamed fallback', () => {
    const caller = { type: 'program' as const, caller_id: 'program_terminal_wins' }
    const streamed = {
      type: 'function_call',
      call_id: 'call_terminal_wins',
      name: 'lookup',
      arguments: '{"query":"stale"}',
      status: 'completed',
      caller
    }
    const terminal = {
      ...streamed,
      arguments: '{"query":"authoritative"}'
    }

    const result = parseOutputItems([terminal] as never, 'gpt-5.6', undefined, undefined, '', undefined, [
      streamed
    ] as never)

    expect(result.message.stopReason).toBe('toolUse')
    expect(result.message.toolCalls).toEqual([
      expect.objectContaining({
        id: 'call_terminal_wins',
        arguments: '{"query":"authoritative"}',
        caller
      })
    ])
  })

  it('rejects a failed terminal call instead of executing the same caller-scoped streamed fallback', () => {
    const caller = { type: 'program' as const, caller_id: 'program_failed_terminal' }
    const streamed = {
      type: 'function_call',
      call_id: 'call_failed_terminal',
      name: 'lookup',
      arguments: '{"query":"stale"}',
      status: 'completed',
      caller
    }
    const terminal = {
      ...streamed,
      status: 'failed'
    }

    const result = parseOutputItems([terminal] as never, 'gpt-5.6', undefined, undefined, '', undefined, [
      streamed
    ] as never)

    expect(result.message.stopReason).toBe('error')
    expect(result.message.toolCalls).toBeUndefined()
    expect(result.hasToolCalls).toBe(false)
    expect(result.message.errorMessage).toBe('AIGateway response ended with an incomplete tool call')
  })

  it('rejects a malformed terminal call instead of executing the same caller-scoped streamed fallback', () => {
    const caller = { type: 'program' as const, caller_id: 'program_malformed_terminal' }
    const streamed = {
      type: 'function_call',
      call_id: 'call_malformed_terminal',
      name: 'lookup',
      arguments: '{"query":"stale"}',
      status: 'completed',
      caller
    }
    const terminal = {
      type: 'function_call',
      call_id: streamed.call_id,
      name: streamed.name,
      status: 'completed',
      caller
    }

    const result = parseOutputItems([terminal] as never, 'gpt-5.6', undefined, undefined, '', undefined, [
      streamed
    ] as never)

    expect(result.message.stopReason).toBe('error')
    expect(result.message.toolCalls).toBeUndefined()
    expect(result.hasToolCalls).toBe(false)
    expect(result.message.errorMessage).toBe('AIGateway response ended with an incomplete tool call')
  })

  it('accepts the exact direct caller shape and rejects ambiguous caller fields', () => {
    const direct = {
      type: 'function_call',
      call_id: 'direct',
      name: 'lookup',
      arguments: '{}',
      status: 'completed',
      caller: { type: 'direct' }
    }

    const valid = parseOutputItems([direct] as never, 'gpt-5.6', undefined)

    expect(valid.message.toolCalls).toEqual([
      expect.objectContaining({
        id: 'direct',
        caller: { type: 'direct' }
      })
    ])

    const invalid = parseOutputItems(
      [
        {
          ...direct,
          caller: { type: 'direct', caller_id: 'forged' }
        }
      ] as never,
      'gpt-5.6',
      undefined
    )

    expect(invalid.message.stopReason).toBe('error')
    expect(invalid.message.toolCalls).toBeUndefined()
    expect(invalid.hasToolCalls).toBe(false)
  })

  it('round-trips custom calls and outputs without a JSON wrapper', () => {
    const patch = '*** Begin Patch\n*** Add File: report.md\n+done\n*** End Patch\n'
    const input = toResponseInput([
      {
        role: 'assistant',
        content: [],
        toolCalls: [
          {
            id: 'call_patch',
            type: 'custom',
            name: 'apply_patch',
            arguments: patch
          }
        ]
      },
      {
        role: 'tool',
        toolCallID: 'call_patch',
        toolCallType: 'custom',
        result: 'Done!'
      }
    ])

    expect(input).toEqual([
      {
        type: 'custom_tool_call',
        call_id: 'call_patch',
        name: 'apply_patch',
        input: patch
      },
      {
        type: 'custom_tool_call_output',
        call_id: 'call_patch',
        output: 'Done!'
      }
    ])
  })

  it('passes image input through as Responses input_image content', async () => {
    const bodies: JSONObject[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        const request = input instanceof Request ? input : new Request(input, init)
        bodies.push(JSON.parse(await request.text()) as JSONObject)

        return new Response(
          JSON.stringify({
            id: 'resp_image',
            object: 'response',
            status: 'completed',
            output: [
              {
                type: 'message',
                role: 'assistant',
                content: [{ type: 'output_text', text: 'seen' }]
              }
            ]
          }),
          { status: 200, headers: { 'content-type': 'application/json' } }
        )
      }) as unknown as typeof fetch
    })

    await callModel(model, {
      messages: [
        {
          role: 'user',
          content: [
            { type: 'text', text: 'look' },
            { type: 'image', image: 'data:image/png;base64,AAA=' }
          ]
        }
      ]
    })

    expect(bodies[0]!.input).toEqual([
      {
        role: 'user',
        content: [
          { type: 'input_text', text: 'look' },
          {
            type: 'input_image',
            image_url: 'data:image/png;base64,AAA=',
            detail: 'auto'
          }
        ]
      }
    ])
  })

  it('encodes binary PNG image input as a base64 PNG data URL', async () => {
    const bodies: JSONObject[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        const request = input instanceof Request ? input : new Request(input, init)
        bodies.push(JSON.parse(await request.text()) as JSONObject)

        return new Response(
          JSON.stringify({
            id: 'resp_binary_image',
            object: 'response',
            status: 'completed',
            output: [
              {
                type: 'message',
                role: 'assistant',
                content: [{ type: 'output_text', text: 'seen' }]
              }
            ]
          }),
          { status: 200, headers: { 'content-type': 'application/json' } }
        )
      }) as unknown as typeof fetch
    })

    const pngBytes = Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
      'base64'
    )

    await callModel(model, {
      messages: [
        {
          role: 'user',
          content: [
            { type: 'text', text: 'look' },
            { type: 'image', mimeType: 'image/png', image: pngBytes }
          ]
        }
      ]
    })

    const input = bodies[0]!.input as Array<{ content: Array<JSONObject> }>
    const imageURL = input[0]!.content[1]!.image_url

    expect(typeof imageURL).toBe('string')
    expect(imageURL).toMatch(/^data:image\/png;base64,[A-Za-z0-9+/]+=*$/)
    expect([
      ...Buffer.from((imageURL as string).slice('data:image/png;base64,'.length), 'base64').subarray(0, 8)
    ]).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  })

  it('passes Responses structured output text format through HTTP calls', async () => {
    const bodies: JSONObject[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        const request = input instanceof Request ? input : new Request(input, init)
        bodies.push(JSON.parse(await request.text()) as JSONObject)

        return new Response(
          JSON.stringify({
            id: 'resp_structured',
            object: 'response',
            status: 'completed',
            output: [
              {
                type: 'message',
                role: 'assistant',
                content: [
                  {
                    type: 'output_text',
                    text: '{"intervene":false,"reason":"quiet"}'
                  }
                ]
              }
            ]
          }),
          { status: 200, headers: { 'content-type': 'application/json' } }
        )
      }) as unknown as typeof fetch
    })

    await callModel(model, {
      messages: [{ role: 'user', content: 'decide' }],
      text: {
        format: {
          type: 'json_schema',
          name: 'ambient_intervention_decision',
          strict: true,
          schema: {
            type: 'object',
            properties: {
              intervene: { type: 'boolean' },
              reason: { type: 'string' }
            },
            required: ['intervene', 'reason'],
            additionalProperties: false
          }
        }
      }
    })

    expect(bodies[0]!.text).toEqual({
      format: expect.objectContaining({
        type: 'json_schema',
        name: 'ambient_intervention_decision'
      })
    })
  })

  it('omits max_output_tokens unless the agent runtime policy provides one', async () => {
    const bodies: JSONObject[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        const request = input instanceof Request ? input : new Request(input, init)
        bodies.push(JSON.parse(await request.text()) as JSONObject)

        return new Response(
          JSON.stringify({
            id: `resp_${bodies.length}`,
            object: 'response',
            status: 'completed',
            output: [
              {
                type: 'message',
                role: 'assistant',
                content: [{ type: 'output_text', text: 'ok' }]
              }
            ]
          }),
          { status: 200, headers: { 'content-type': 'application/json' } }
        )
      }) as unknown as typeof fetch
    })

    await callModel(model, {
      messages: [{ role: 'user', content: 'uncapped' }]
    })
    await callModel(model, {
      messages: [{ role: 'user', content: 'capped' }],
      maxOutputTokens: 12_000
    })

    expect(Object.hasOwn(bodies[0]!, 'max_output_tokens')).toBe(false)
    expect(bodies[1]!.max_output_tokens).toBe(12_000)
  })

  it('reads normalized usage details from AIGateway Responses results', async () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async () =>
        new Response(
          JSON.stringify({
            id: 'resp_usage',
            object: 'response',
            status: 'completed',
            output: [
              {
                type: 'message',
                role: 'assistant',
                content: [{ type: 'output_text', text: 'seen' }]
              }
            ],
            usage: {
              input_tokens: 17,
              output_tokens: 5,
              total_tokens: 22,
              input_tokens_details: { cached_tokens: 3 },
              output_tokens_details: { reasoning_tokens: 2 }
            }
          }),
          { status: 200, headers: { 'content-type': 'application/json' } }
        )) as unknown as typeof fetch
    })

    const result = await callModel(model, {
      messages: [{ role: 'user', content: 'measure' }]
    })

    expect(result.message.usage).toEqual({
      inputTokens: 17,
      outputTokens: 5,
      reasoningTokens: 2,
      cachedInputTokens: 3
    })
  })

  it('passes abortSignal through HTTP Responses calls', async () => {
    const controller = new AbortController()
    let fetchCalled = false
    let requestSignalAborted = false
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        fetchCalled = true
        const requestSignal = init?.signal ?? (input instanceof Request ? input.signal : undefined)
        if (!requestSignal) throw new Error('missing abort signal')

        queueMicrotask(() => controller.abort(new DOMException('operator stop', 'AbortError')))

        return await new Promise<Response>((_resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('abort signal did not fire')), 50)
          requestSignal.addEventListener(
            'abort',
            () => {
              clearTimeout(timer)
              requestSignalAborted = true
              reject(new Error('request signal aborted'))
            },
            { once: true }
          )
        })
      }) as unknown as typeof fetch
    })

    let rejected = false
    try {
      await callModel(model, {
        messages: [{ role: 'user', content: 'wait' }],
        abortSignal: controller.signal
      })
    } catch {
      rejected = true
    }

    expect(rejected).toBe(true)
    expect(fetchCalled).toBe(true)
    expect(requestSignalAborted).toBe(true)
  })

  it('classifies AIGateway WebSocket transport failures as retryable timeouts', () => {
    const beforeOpen = Object.assign(new Error('AIGateway WebSocket closed before open'), {
      details: { local_retryable: true }
    })
    const afterSend = Object.assign(new Error('AIGateway WebSocket closed before response.completed'), {
      details: { local_retryable: false }
    })

    for (const error of [
      beforeOpen,
      afterSend,
      new Error('AIGateway WebSocket transport error'),
      new Error('LLM provider call aborted')
    ]) {
      expect(classifyLLMError(error)).toMatchObject({
        kind: 'timeout',
        retryable: true
      })
    }

    expect(isLocallyRetryableLLMError(beforeOpen)).toBe(true)
    expect(isLocallyRetryableLLMError(afterSend)).toBe(false)
  })

  it('classifies Codex stream disconnects and upstream gateway statuses as transient', () => {
    expect(classifyLLMError(new Error('stream disconnected before completion'))).toMatchObject({
      kind: 'timeout',
      retryable: true
    })

    expect(
      classifyLLMError(
        Object.assign(new Error('error decoding response body'), {
          code: 'upstream_read_failed',
          details: { stage: 'read' }
        })
      )
    ).toMatchObject({
      kind: 'timeout',
      retryable: true
    })

    for (const status of [502, 503, 504]) {
      expect(classifyLLMError(new Error(`upstream returned HTTP status ${status}`))).toMatchObject({
        kind: 'server',
        retryable: true
      })
    }
  })

  it('classifies incomplete terminal reason fallbacks without retrying blindly', () => {
    expect(classifyLLMError(new Error('AIGateway response incomplete reason=content_filter'))).toMatchObject({
      kind: 'content_filter',
      retryable: false,
      shouldCompress: false,
      shouldFallbackProvider: false
    })
    expect(classifyLLMError(new Error('max_output_tokens'))).toMatchObject({
      kind: 'overflow',
      retryable: false,
      shouldCompress: true,
      shouldFallbackProvider: false
    })
  })

  it('sends stateful response.create over AIGateway WebSocket', async () => {
    const sentPayloads: JSONObject[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            sentPayloads.push(JSON.parse(data) as JSONObject)
            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_message_1',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'hello' }]
                    }
                  ],
                  usage: { input_tokens: 3, output_tokens: 2 }
                }
              }
            ]
          })
      }
    })

    const result = await callModel(model, {
      instructions: 'system prompt',
      messages: [{ role: 'user', content: 'hi' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000001',
        conversationID: '11111111-1111-1111-1111-111111111111'
      }
    })

    expect(result.responseID).toBe('resp_message_1')
    expect(result.message.content).toEqual([{ type: 'text', text: 'hello' }])
    expect(sentPayloads).toHaveLength(1)
    expect(sentPayloads[0]).toMatchObject({
      type: 'response.create',
      model: 'primary',
      instructions: 'system prompt',
      store: true,
      conversation: 'conv_11111111-1111-1111-1111-111111111111',
      metadata: { actor_event_id: '00000000-0000-0000-0000-000000000001' },
      input: [{ role: 'user', content: 'hi' }]
    })
    expect(JSON.stringify(sentPayloads[0]!.input)).not.toContain('system prompt')
  })

  it('omits PTC when every tool is direct-only', async () => {
    const sentPayloads: JSONObject[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            sentPayloads.push(JSON.parse(data) as JSONObject)
            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_ptc_default',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'done' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    await runAgentLoop({
      model,
      maxModelIterations: 3,
      messages: [{ role: 'user', content: 'check tools' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000018',
        conversationID: '18181818-1818-1818-1818-181818181818'
      },
      tools: [
        {
          name: 'lookup',
          description: 'Read one value.',
          schema: z.object({ key: z.string() }),
          isReadOnly: true,
          isDestructive: false,
          describeActivity: () => '查询',
          execute: async () => ({
            content: [{ type: 'text', text: 'value' }],
            details: {}
          })
        },
        {
          name: 'write',
          description: 'Write one value.',
          schema: z.object({ key: z.string() }),
          isReadOnly: false,
          isDestructive: true,
          describeActivity: () => '写入',
          execute: async () => ({
            content: [{ type: 'text', text: 'ok' }],
            details: {}
          })
        }
      ]
    })

    expect(sentPayloads[0]!.tools).toEqual([
      expect.objectContaining({
        name: 'lookup',
        allowed_callers: ['direct']
      }),
      expect.objectContaining({ name: 'write', allowed_callers: ['direct'] })
    ])
  })

  it('keeps user text parts as Responses input_text parts', async () => {
    const sentPayloads: JSONObject[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            sentPayloads.push(JSON.parse(data) as JSONObject)
            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_message_parts',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'ok' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    await callModel(model, {
      messages: [
        {
          role: 'user',
          content: [
            {
              type: 'text',
              text: '<agent_environment_info>\nroom: Ops\n</agent_environment_info>'
            },
            { type: 'text', text: 'Deploy status?' }
          ]
        }
      ],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000701',
        conversationID: '77777777-7777-7777-7777-777777777777'
      }
    })

    expect(sentPayloads[0]).toMatchObject({
      input: [
        {
          role: 'user',
          content: [
            {
              type: 'input_text',
              text: '<agent_environment_info>\nroom: Ops\n</agent_environment_info>'
            },
            { type: 'input_text', text: 'Deploy status?' }
          ]
        }
      ]
    })
  })

  it('uses the native WebSocket constructor when no test socket factory is injected', async () => {
    const sentPayloads: JSONObject[] = []
    const server = Bun.serve({
      port: 0,
      fetch(request, server) {
        if (server.upgrade(request)) return
        return new Response('not found', { status: 404 })
      },
      websocket: {
        message(ws, message) {
          const text = typeof message === 'string' ? message : new TextDecoder().decode(message as BufferSource)
          sentPayloads.push(JSON.parse(text) as JSONObject)
          ws.send(
            JSON.stringify({
              type: 'response.completed',
              response: {
                id: 'resp_native_ws',
                status: 'completed',
                output: [
                  {
                    type: 'message',
                    role: 'assistant',
                    content: [{ type: 'output_text', text: 'native websocket ok' }]
                  }
                ]
              }
            })
          )
        }
      }
    })

    try {
      const model = createModel({
        apiKey: 'unused',
        baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
        selector: 'primary',
        responseWebSocket: {
          kind: 'aigateway-websocket',
          url: `ws://127.0.0.1:${server.port}/responses`,
          authorization: () => 'Bearer agent-key'
        }
      })

      const result = await callModel(model, {
        messages: [{ role: 'user', content: 'hi' }],
        stateful: {
          actorEventID: '00000000-0000-0000-0000-000000000012',
          conversationID: 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        }
      })

      expect(result.responseID).toBe('resp_native_ws')
      expect(result.message.content).toEqual([{ type: 'text', text: 'native websocket ok' }])
      expect(sentPayloads).toHaveLength(1)
      expect(sentPayloads[0]).toMatchObject({
        type: 'response.create',
        conversation: 'conv_cccccccc-cccc-cccc-cccc-cccccccccccc'
      })
    } finally {
      server.stop(true)
    }
  })

  it('uses output_item.done items when a terminal WebSocket frame has empty output', async () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, () => [
            {
              type: 'response.output_item.done',
              item: {
                type: 'message',
                role: 'assistant',
                content: [{ type: 'output_text', text: 'stable item text' }]
              }
            },
            {
              type: 'response.completed',
              response: {
                id: 'resp_empty_terminal_output',
                status: 'completed',
                output: []
              }
            }
          ])
      }
    })

    const result = await callModel(model, {
      messages: [{ role: 'user', content: 'hi' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000013',
        conversationID: 'dddddddd-dddd-dddd-dddd-dddddddddddd'
      }
    })

    expect(result.responseID).toBe('resp_empty_terminal_output')
    expect(result.message.content).toEqual([{ type: 'text', text: 'stable item text' }])
    expect(result.message.stopReason).toBe('stop')
  })

  it('maps max_output_tokens response.incomplete terminals to length while preserving output', async () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, () => [
            {
              type: 'response.incomplete',
              response: {
                id: 'resp_incomplete',
                status: 'incomplete',
                incomplete_details: { reason: 'max_output_tokens' },
                output: [
                  {
                    type: 'message',
                    role: 'assistant',
                    content: [{ type: 'output_text', text: 'partial answer' }]
                  }
                ]
              }
            }
          ])
      }
    })

    const result = await callModel(model, {
      messages: [{ role: 'user', content: 'hi' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000014',
        conversationID: 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
      }
    })

    expect(result.responseID).toBe('resp_incomplete')
    expect(result.message.content).toEqual([{ type: 'text', text: 'partial answer' }])
    expect(result.message.stopReason).toBe('length')
    expect(result.message.errorMessage).toBeUndefined()
  })

  it('reports max_output_tokens with a partial function call as length with a truncation record, never executable output', async () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, () => [
            {
              type: 'response.incomplete',
              response: {
                id: 'resp_partial_length',
                status: 'incomplete',
                incomplete_details: { reason: 'max_output_tokens' },
                output: [
                  {
                    type: 'function_call',
                    status: 'incomplete',
                    id: 'fc_partial_length',
                    call_id: 'call_partial_length',
                    name: 'patch',
                    arguments: '{"path":"/tmp/repor'
                  }
                ]
              }
            }
          ])
      }
    })

    const result = await callModel(model, {
      messages: [{ role: 'user', content: 'write a report' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000020',
        conversationID: '20202020-2020-2020-2020-202020202020'
      }
    })

    expect(result.message.stopReason).toBe('length')
    expect(result.message.toolCalls).toBeUndefined()
    expect(result.hasToolCalls).toBe(false)
    expect(result.message.errorMessage).toBeUndefined()
    expect(result.message.truncatedToolCalls).toEqual([
      {
        name: 'patch',
        argumentsComplete: false,
        argumentChars: 19,
        completedFields: [],
        cutField: 'path',
        cutFieldChars: 10
      }
    ])
  })

  it('treats an unkeyed function-call fragment as a malformed terminal instead of dropping it', async () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, () => [
            {
              type: 'response.completed',
              response: {
                id: 'resp_unkeyed_call',
                status: 'completed',
                output: [
                  {
                    type: 'function_call',
                    status: 'completed',
                    name: 'patch',
                    arguments: '{}'
                  }
                ]
              }
            }
          ])
      }
    })

    const result = await callModel(model, {
      messages: [{ role: 'user', content: 'write a report' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000021',
        conversationID: '21212121-2121-2121-2121-212121212121'
      }
    })

    expect(result.message.stopReason).toBe('error')
    expect(result.message.toolCalls).toBeUndefined()
    expect(result.hasToolCalls).toBe(false)
    expect(result.message.errorMessage).toBe('AIGateway response ended with an incomplete tool call')
  })

  it('does not execute a tool call with a malformed program caller', async () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, () => [
            {
              type: 'response.completed',
              response: {
                id: 'resp_invalid_caller',
                status: 'completed',
                output: [
                  {
                    type: 'function_call',
                    status: 'completed',
                    call_id: 'call_invalid_caller',
                    name: 'lookup',
                    arguments: '{}',
                    caller: { type: 'program', caller_id: '' }
                  }
                ]
              }
            }
          ])
      }
    })

    const result = await callModel(model, {
      messages: [{ role: 'user', content: 'look this up' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000022',
        conversationID: '22222222-2222-2222-2222-222222222222'
      }
    })

    expect(result.message.stopReason).toBe('error')
    expect(result.message.toolCalls).toBeUndefined()
    expect(result.hasToolCalls).toBe(false)
    expect(result.message.errorMessage).toBe('AIGateway response ended with an incomplete tool call')
  })

  it('maps content_filter response.incomplete terminals to an error assistant message', async () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, () => [
            {
              type: 'response.incomplete',
              response: {
                id: 'resp_content_filter',
                status: 'incomplete',
                incomplete_details: { reason: 'content_filter' },
                output: [
                  {
                    type: 'message',
                    role: 'assistant',
                    content: [{ type: 'output_text', text: 'filtered partial answer' }]
                  }
                ]
              }
            }
          ])
      }
    })

    const result = await callModel(model, {
      messages: [{ role: 'user', content: 'hi' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000016',
        conversationID: '16161616-1616-1616-1616-161616161616'
      }
    })

    expect(result.responseID).toBe('resp_content_filter')
    expect(result.message.content).toEqual([{ type: 'text', text: 'filtered partial answer' }])
    expect(result.message.stopReason).toBe('error')
    expect(result.message.errorMessage).toBe('AIGateway response incomplete reason=content_filter')
  })

  it('lets the agent loop return max_output_tokens incomplete output as a bounded partial answer', async () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, () => [
            {
              type: 'response.incomplete',
              response: {
                id: 'resp_loop_incomplete',
                status: 'incomplete',
                incomplete_details: { reason: 'max_output_tokens' },
                output: [
                  {
                    type: 'message',
                    role: 'assistant',
                    content: [{ type: 'output_text', text: 'partial loop answer' }]
                  }
                ]
              }
            }
          ])
      }
    })

    const final = await runAgentLoop({
      model,
      maxModelIterations: 90,
      messages: [{ role: 'user', content: 'write a long answer' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000017',
        conversationID: '17171717-1717-1717-1717-171717171717'
      }
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'partial loop answer' }])
    expect(final.message.stopReason).toBe('length')
    expect(final.message.errorMessage).toBeUndefined()
  })
})
