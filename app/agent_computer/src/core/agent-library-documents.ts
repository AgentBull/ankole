import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { writeFileAtomicSync } from '../common/atomic-write'
import { type AgentConversationContextResponse } from '../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { AgentHomePaths } from './agent-home-paths'

/**
 * Projects PostgreSQL-owned Agent documents into Agent Home as read-only files.
 * The turn uses the received snapshot.
 */
export function materializeAgentLibraryDocuments(
  paths: AgentHomePaths,
  context: AgentConversationContextResponse
): AgentConversationContextResponse {
  mkdirSync(paths.codexHome, { recursive: true })
  writeFileAtomicSync(paths.agents, context.agents, 0o444)
  writeFileAtomicSync(join(paths.codexHome, 'AGENTS.md'), context.agents, 0o444)
  writeFileAtomicSync(paths.design, context.design, 0o444)
  return context
}
