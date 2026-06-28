import { AISDKError } from '@/ai-gateway-client/provider'

const name = 'AI_InvalidMessageRoleError'
const marker = `com.agentbull.ankole-ai-gateway.client.error.${name}`
const symbol = Symbol.for(marker)

export class InvalidMessageRoleError extends AISDKError {
  private readonly [symbol] = true // used in isInstance

  readonly role: string

  constructor({
    role,
    message = `Invalid message role: '${role}'. Must be one of: "system", "user", "assistant", "tool".`
  }: {
    role: string
    message?: string
  }) {
    super({ name, message })

    this.role = role
  }

  static isInstance(error: unknown): error is InvalidMessageRoleError {
    return AISDKError.hasMarker(error, marker)
  }
}
