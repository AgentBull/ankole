import { z } from 'zod'
import type { JobTurnRef } from '../../lanes/session_lane'
import { defineWorkerTool, type WorkerAgentTool } from '../../core'
import type { RPCRequester, RuntimeSkillSummary } from '../../lanes/rpc_lane'
import { createSkillLoader, type SkillLoadDetails, type SkillLoader } from '../../skills/skill-loader'

// `name` is the enabled skill name from RuntimeFabric. `filePath` lets the model
// follow references out of SKILL.md without a second tool, but resolution always
// stays inside the skill's source directory.
const SkillViewParams = z.object({
  name: z.string().min(1).describe('Enabled skill name to read.'),
  filePath: z.string().optional().describe('Skill-relative file path. Defaults to SKILL.md.')
})

export interface CreateSkillToolsOptions {
  turn: JobTurnRef
  enabledSkills?: RuntimeSkillSummary[]
  rpc: RPCRequester
  loader?: SkillLoader
}

/** Creates the Job adapter for the control-plane skill_view contract. */
export function createSkillTools(opts: CreateSkillToolsOptions): WorkerAgentTool[] {
  const loader =
    opts.loader ??
    createSkillLoader({
      turn: opts.turn,
      enabledSkills: opts.enabledSkills,
      rpc: opts.rpc
    })
  return [createSkillViewTool(loader)]
}

/**
 * The system prompt lists Skills as an index. A missing Skill source throws:
 * enabling a Skill is a control-plane decision.
 */
export function createSkillViewTool(loader: SkillLoader): WorkerAgentTool<typeof SkillViewParams, SkillLoadDetails> {
  return defineWorkerTool({
    name: 'skill_view',
    description:
      'Read an enabled Skill file for this background agent job. skill_view loads its full instructions. Read referenced files only when needed and resolve relative paths from the returned Skill directory. This tool cannot enable disabled Skills.',
    schema: SkillViewParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: params => ({
      key: 'signals_gateway.reply.activity.skill_load',
      bindings: { name: params.name }
    }),
    async execute(_toolCallId, params) {
      return await loader.load(params)
    }
  })
}
