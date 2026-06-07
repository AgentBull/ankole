import type { ExternalGatewayOutboundIntent } from '@/external-gateway/outbox'

export type AiAgentCommandName = 'new' | 'compress' | 'retry' | 'steer' | 'stop'

export function commandFeedbackIntent(input: {
  commandEventId: string
  phase?: string
  providerRoomId: string
  providerThreadId: string
  text: string
}): ExternalGatewayOutboundIntent {
  return {
    operation: 'post',
    outboundKey: `ai-agent-command-feedback:${input.commandEventId}:${input.phase ?? 'final'}`,
    providerRoomId: input.providerRoomId,
    providerThreadId: input.providerThreadId,
    finalPayload: { text: input.text }
  }
}

export function commandEditIntent(input: {
  commandEventId: string
  providerRoomId: string
  providerThreadId: string
  targetOutboundKey: string
  text: string
}): ExternalGatewayOutboundIntent {
  return {
    operation: 'edit',
    outboundKey: `ai-agent-command-feedback:${input.commandEventId}:edit`,
    providerRoomId: input.providerRoomId,
    providerThreadId: input.providerThreadId,
    finalPayload: {
      targetOutboundKey: input.targetOutboundKey,
      text: input.text
    }
  }
}
