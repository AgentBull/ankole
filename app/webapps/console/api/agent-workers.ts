import { fromDocument } from './json-api'
import { listAgentWorkersOptions } from './v2/generated/@tanstack/react-query.gen'
import type { ListAgentWorkersResponse } from './v2/generated/types.gen'

/** The v2 document names a Worker by its Agent; the flat record keeps it as `agent_uid`. */
function workersFromDocument(document: ListAgentWorkersResponse) {
  return fromDocument(document).map(({ id, ...worker }) => ({ ...worker, agent_uid: id }))
}

export type AgentWorkerItem = ReturnType<typeof workersFromDocument>[number]

/** The query of the Worker of each Agent, with the flat records as its data. */
export function agentWorkerListOptions() {
  return { ...listAgentWorkersOptions(), select: workersFromDocument }
}
