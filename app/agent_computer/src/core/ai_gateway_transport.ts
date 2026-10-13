import { ms } from '@agentbull/active-support'
import { Buffer } from 'node:buffer'
import type { TurnTracePropagation } from '../observability/turn-tracing'

export const aiGatewayAPIKeyRefreshSkewMs = ms('1m')
const noObservabilityUserID = 'none'

export const AIGATEWAY_OBSERVABILITY_USER_ID_HEADER = 'x-ankole-observability-user-id'

/**
 * Builds the trusted trace headers for one AIGateway request.
 *
 * The user value uses an ASCII-safe base64url carrier. AIGateway decodes it
 * before it records `user.id`, and the carrier never reaches a model Provider.
 */
export function aiGatewayTurnTraceHeaders(turnTracePropagation?: TurnTracePropagation): Record<string, string> {
  if (!turnTracePropagation) return {}

  return {
    traceparent: turnTracePropagation.traceparent,
    [AIGATEWAY_OBSERVABILITY_USER_ID_HEADER]:
      turnTracePropagation.observabilityUserID === null
        ? noObservabilityUserID
        : Buffer.from(turnTracePropagation.observabilityUserID, 'utf8').toString('base64url')
  }
}
