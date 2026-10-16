import type { AgentToolResult } from '../core'
import type { JobTurnRef } from '../lanes/session_lane'
import { type RPCRequester } from '../lanes/rpc_lane'
import { type RuntimeSkillSummary } from '../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { enabledSkillByName } from './effective-skill'
import { readTool } from '../core/read-tools'

export type SkillLoadParams = {
  name: string
  filePath?: string
}

export type SkillLoadDetails = {
  name: string
  path: string
}

export type SkillLoader = {
  load(params: SkillLoadParams): Promise<AgentToolResult<SkillLoadDetails>>
  disable(names: string[]): void
}

export type CreateSkillLoaderOptions = {
  turn: JobTurnRef
  enabledSkills?: RuntimeSkillSummary[]
  rpc: RPCRequester
  onSkillLoaded?: (name: string) => void
}

/** The control plane owns enablement, runtime policy, source reads and lessons. */
export function createSkillLoader(opts: CreateSkillLoaderOptions): SkillLoader {
  const disabled = new Set<string>()
  return {
    disable(names) {
      for (const name of names) disabled.add(name)
    },
    async load(params) {
      if (disabled.has(params.name)) throw new Error(`skill is not enabled for this turn: ${params.name}`)
      enabledSkillByName(params.name, opts.enabledSkills)
      const result = await readTool(opts.rpc, opts.turn, 'skill_view', {
        name: params.name,
        ...(params.filePath ? { filePath: params.filePath } : {})
      })
      opts.onSkillLoaded?.(params.name)
      return { ...result, details: { name: params.name, path: params.filePath ?? 'SKILL.md' } }
    }
  }
}
