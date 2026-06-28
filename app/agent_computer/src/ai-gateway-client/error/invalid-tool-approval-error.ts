import { AISDKError } from '@/ai-gateway-client/provider'

const name = 'AI_InvalidToolApprovalError'
const marker = `com.agentbull.ankole-ai-gateway.client.error.${name}`
const symbol = Symbol.for(marker)

export class InvalidToolApprovalError extends AISDKError {
  private readonly [symbol] = true // used in isInstance

  readonly approvalId: string

  constructor({ approvalId }: { approvalId: string }) {
    super({
      name,
      message:
        `Tool approval response references unknown approvalId: "${approvalId}". ` +
        `No matching tool-approval-request found in message history.`
    })

    this.approvalId = approvalId
  }

  static isInstance(error: unknown): error is InvalidToolApprovalError {
    return AISDKError.hasMarker(error, marker)
  }
}
