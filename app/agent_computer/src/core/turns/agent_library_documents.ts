import { chmodSync, lstatSync, mkdirSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import type { AgentConversationContext } from '../../lanes/rpc_lane'
import { resolveWorkspacePath } from '../workspace-paths'

export const AGENT_DESIGN_DOCUMENT_PATH = '/workspace/.ankole/agent-library/DESIGN.md'

/**
 * Synchronizes the control-plane-owned DESIGN document into the current
 * session workspace without adding its contents to the model prompt.
 */
export function materializeAgentLibraryDocuments(workspaceRoot: string, context: AgentConversationContext): void {
  const designPath = resolveWorkspacePath(workspaceRoot, AGENT_DESIGN_DOCUMENT_PATH)
  const root = dirname(designPath)
  ensureRuntimeDirectory(dirname(root))
  ensureRuntimeDirectory(root)

  if (typeof context.design !== 'string') {
    rmSync(designPath, { force: true })
    return
  }

  const temporaryPath = `${designPath}.${process.pid}.${crypto.randomUUID()}.tmp`

  try {
    writeFileSync(temporaryPath, context.design, { mode: 0o444 })
    renameSync(temporaryPath, designPath)
  } finally {
    rmSync(temporaryPath, { force: true })
  }
}

/** Reclaims the reserved projection path from stale files or symbolic links. */
function ensureRuntimeDirectory(path: string): void {
  try {
    const stat = lstatSync(path)
    if (stat.isSymbolicLink() || !stat.isDirectory()) rmSync(path, { recursive: true, force: true })
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }

  mkdirSync(path, { recursive: true, mode: 0o700 })
  chmodSync(path, 0o700)
}
