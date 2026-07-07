import OpenAI from 'openai'
import type { ModelConfig, ResponseWebSocketTransport } from './types'

export function createModel(opts: {
  apiKey: string
  baseURL: string
  selector: string
  name?: string
  provider?: string
  fetch?: typeof fetch
  responseWebSocket?: ResponseWebSocketTransport
}): ModelConfig {
  const client = new OpenAI({
    apiKey: opts.apiKey,
    baseURL: opts.baseURL,
    fetch: opts.fetch as never
  })

  return {
    client,
    selector: opts.selector,
    name: opts.name ?? (opts.selector.includes('/') ? opts.selector.split('/').pop()! : opts.selector),
    provider: opts.provider ?? 'ai-gateway',
    responseWebSocket: opts.responseWebSocket
  }
}
