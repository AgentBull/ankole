import { writeFileAtomicSync } from '../../../common/atomic-write'
import type { AgentConversationContextResponse } from '../../../lanes/rpc_lane'
import type { AgentHomePaths } from '../../agent-home-paths'

/**
 * Projects PostgreSQL-owned Agent documents into Agent Home as read-only files.
 * The turn uses the received snapshot.
 */
export function materializeAgentLibraryDocuments(
  paths: AgentHomePaths,
  context: AgentConversationContextResponse
): AgentConversationContextResponse {
  writeFileAtomicSync(paths.soul, context.soul, 0o444)
  writeFileAtomicSync(paths.mission, context.mission, 0o444)
  writeFileAtomicSync(paths.design, context.design, 0o444)
  writeFileAtomicSync(paths.confidentialityPolicy, context.confidentialityPolicy, 0o444)
  return context
}
