import { chmodSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { xxh3String128Hex } from '@ankole/kernel'
import type { AgentConversationContextResponse } from '../../lanes/rpc_lane'
import type { AgentHomePaths } from '../agent-home-paths'

/**
 * Synchronizes PostgreSQL-owned Agent documents into Agent Home and then reads
 * the filesystem projection used by the turn.
 */
export function materializeAgentLibraryDocuments(
  paths: AgentHomePaths,
  context: AgentConversationContextResponse
): AgentConversationContextResponse {
  verifyProjectionContent('SOUL.md', context.soul, context.soulContentHash)
  verifyProjectionContent('MISSION.md', context.mission, context.missionContentHash)
  verifyProjectionContent('DESIGN.md', context.design, context.designContentHash)
  atomicProjection(paths.soul, context.soul)
  atomicProjection(paths.mission, context.mission)
  atomicProjection(paths.design, context.design)
  const soul = readVerifiedProjection('SOUL.md', paths.soul, context.soulContentHash)
  const mission = readVerifiedProjection('MISSION.md', paths.mission, context.missionContentHash)
  const design = readVerifiedProjection('DESIGN.md', paths.design, context.designContentHash)
  return {
    ...context,
    soul,
    mission,
    design
  }
}

function verifyProjectionContent(label: string, content: string, expectedHash: string): void {
  if (!expectedHash || xxh3String128Hex(content) !== expectedHash) {
    throw new Error(`${label} projection content hash mismatch`)
  }
}

function readVerifiedProjection(label: string, path: string, expectedHash: string): string {
  const content = readFileSync(path, 'utf8')
  verifyProjectionContent(label, content, expectedHash)
  return content
}

function atomicProjection(path: string, content: string): void {
  const temporaryPath = `${path}.${process.pid}.${crypto.randomUUID()}.tmp`
  try {
    writeFileSync(temporaryPath, content, { mode: 0o444 })
    renameSync(temporaryPath, path)
    chmodSync(path, 0o444)
  } finally {
    rmSync(temporaryPath, { force: true })
  }
}
