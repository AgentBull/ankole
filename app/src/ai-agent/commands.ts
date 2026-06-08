import { bullxInteractiveOutputVersion, type BullXInteractiveOutput } from '@agentbull/bullx-sdk/plugins'
import { toJsonObject } from '@/common/json'
import { interactiveOutputCardPayload } from '@/external-gateway/interactive-output'
import type { ExternalGatewayOutboundIntent } from '@/external-gateway/outbox'

export type AiAgentCommandName = 'new' | 'compress' | 'retry' | 'steer' | 'stop'

export type ControlNoticeSurface = 'dm' | 'group'

export interface ControlNoticeCaps {
  dividerCapable: boolean
  cardCapable: boolean
}

/**
 * Pick the outbound operation for a command/control-notice feedback by surface +
 * adapter capabilities (Elixir `render_control_notice` parity): DM prefers a
 * divider system message, a group prefers a compact notice card, and channels
 * that support neither fall back to a plain post.
 */
export function controlNoticeOperation(
  surface: ControlNoticeSurface,
  caps: ControlNoticeCaps
): 'divider' | 'card' | 'post' {
  if (surface === 'dm' && caps.dividerCapable) return 'divider'
  if (surface === 'group' && caps.cardCapable) return 'card'
  return 'post'
}

export function commandFeedbackIntent(input: {
  commandEventId: string
  phase?: string
  providerRoomId: string
  providerThreadId: string
  text: string
  surface?: ControlNoticeSurface
  caps?: ControlNoticeCaps
}): ExternalGatewayOutboundIntent {
  const operation = input.surface && input.caps ? controlNoticeOperation(input.surface, input.caps) : 'post'
  // The outboundKey is operation-independent so idempotency/recovery keys stay
  // stable even when the chosen surface flips divider/card/post.
  return {
    operation,
    outboundKey: `ai-agent-command-feedback:${input.commandEventId}:${input.phase ?? 'final'}`,
    providerRoomId: input.providerRoomId,
    providerThreadId: input.providerThreadId,
    finalPayload:
      operation === 'post'
        ? { text: input.text }
        : operation === 'divider'
          ? { kind: 'control_notice', text: input.text, fallbackText: input.text }
          : toJsonObject(interactiveOutputCardPayload(noticeOutput(input.text)))
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

function noticeOutput(text: string): BullXInteractiveOutput {
  return {
    version: bullxInteractiveOutputVersion,
    content: {
      body: text,
      format: 'plain',
      severity: 'neutral'
    },
    state: { status: 'open' },
    fallbackText: text
  }
}
