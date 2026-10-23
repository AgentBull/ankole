import { fromDocument } from './json-api'
import { getAgentOptions, listAgentsOptions } from './v2/generated/@tanstack/react-query.gen'
import type { GetAgentResponse, ListAgentsResponse } from './v2/generated/types.gen'

/**
 * The Console names an Agent by the UID of its Principal. The v2 document
 * gives the UID as the resource `id`; the flat record keeps it as `uid`.
 */
export function agentsFromDocument(document: ListAgentsResponse) {
  return fromDocument(document).map(({ id, ...agent }) => ({ ...agent, uid: id }))
}

export type AgentItem = ReturnType<typeof agentsFromDocument>[number]

function agentFromDocument(document: GetAgentResponse): AgentItem {
  const { id, ...agent } = fromDocument(document)
  return { ...agent, uid: id }
}

/** The query of the Agent list, with the flat records as its data. */
export function agentListOptions() {
  return { ...listAgentsOptions(), select: agentsFromDocument }
}

/** The query of one Agent, with the flat record as its data. */
export function agentOptions(uid: string) {
  return { ...getAgentOptions({ path: { uid } }), select: agentFromDocument }
}
