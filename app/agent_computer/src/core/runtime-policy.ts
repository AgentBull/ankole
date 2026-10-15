import type { TurnStart } from '../lanes/session_lane'
import { isRecord } from '@agentbull/active-support'

/**
 * True when the Agent leaves web search to its language-model Provider.
 *
 * The Worker then declares no `web_search` tool at all. That holds even when the
 * Provider turns out not to run search: the Agent said search belongs to its
 * model, so quietly substituting an Ankole search Provider would change who
 * executes the work and what the result looks like.
 *
 * Whether the Provider actually performs a search this turn is a separate fact,
 * carried by the hosted tool declaration.
 */
export function webSearchIsProviderHosted(turnStart: TurnStart): boolean {
  const rawPolicy = turnStart.request_context?.ai_agent
  const policy = isRecord(rawPolicy) ? rawPolicy : {}
  const hosted = isRecord(policy.provider_hosted) ? policy.provider_hosted : {}
  return hosted.web_search === true
}
