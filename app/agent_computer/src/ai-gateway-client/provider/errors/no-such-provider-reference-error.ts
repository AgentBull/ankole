import type { SharedProviderReference } from '../shared/shared-provider-reference'
import { AISDKError } from './ai-sdk-error'

const name = 'AI_NoSuchProviderReferenceError'
const marker = `com.agentbull.ankole-ai-gateway.client.error.${name}`
const symbol = Symbol.for(marker)

/**
 * Thrown when a provider reference cannot be resolved because the specified
 * provider is not found in the provider reference mapping.
 */
export class NoSuchProviderReferenceError extends AISDKError {
  private readonly [symbol] = true // used in isInstance

  readonly provider: string
  readonly reference: SharedProviderReference

  constructor({
    provider,
    reference,
    message = `No provider reference found for provider '${provider}'. Available providers: ${Object.keys(reference).join(', ')}`
  }: {
    provider: string
    reference: SharedProviderReference
    message?: string
  }) {
    super({ name, message })
    this.provider = provider
    this.reference = reference
  }

  static isInstance(error: unknown): error is NoSuchProviderReferenceError {
    return AISDKError.hasMarker(error, marker)
  }
}
