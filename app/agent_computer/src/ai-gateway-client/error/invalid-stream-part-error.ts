import { AISDKError } from '@/ai-gateway-client/provider'
import type { LanguageModelStreamPart } from '../generate-text/stream-language-model-call'

const name = 'AI_InvalidStreamPartError'
const marker = `com.agentbull.ankole-ai-gateway.client.error.${name}`
const symbol = Symbol.for(marker)

export class InvalidStreamPartError extends AISDKError {
  private readonly [symbol] = true // used in isInstance

  readonly chunk: LanguageModelStreamPart<any>

  constructor({ chunk, message }: { chunk: LanguageModelStreamPart<any>; message: string }) {
    super({ name, message })

    this.chunk = chunk
  }

  static isInstance(error: unknown): error is InvalidStreamPartError {
    return AISDKError.hasMarker(error, marker)
  }
}
