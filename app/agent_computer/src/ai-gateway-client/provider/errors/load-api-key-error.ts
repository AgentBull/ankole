import { AISDKError } from './ai-sdk-error'

const name = 'AI_LoadAPIKeyError'
const marker = `com.agentbull.ankole-ai-gateway.client.error.${name}`
const symbol = Symbol.for(marker)

export class LoadAPIKeyError extends AISDKError {
  private readonly [symbol] = true // used in isInstance

  constructor({ message }: { message: string }) {
    super({ name, message })
  }

  static isInstance(error: unknown): error is LoadAPIKeyError {
    return AISDKError.hasMarker(error, marker)
  }
}
