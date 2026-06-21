import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../core'
import { buildTool } from '../tools/build-tool'
import { getEffectiveSkillContent, setAgentSkillAppend } from './service'
import { wrapExternalContent } from '@/security/external-content'

export interface SkillToolsBinding {
  agentUid: string
}

const SkillViewParams = z.object({
  name: z.string().min(1).describe('The skill name. Choose from the <available_skills> index in the system prompt.'),
  filePath: z
    .string()
    .optional()
    .describe(
      "OPTIONAL: Path to a linked file within the skill (e.g., 'references/api.md', 'templates/config.yaml', 'scripts/validate.py'). Omit to get the main SKILL.md content."
    )
})

const SkillAppendParams = z.object({
  name: z.string().min(1).describe('Skill name to customize for this agent.'),
  content: z.string().describe('Complete AGENT_APPEND.md content for this agent and skill.')
})

/**
 * Creates the model-facing skill tools bound to one agent's effective library.
 */
export function createSkillTools(binding: SkillToolsBinding): AgentTool<any>[] {
  return [createSkillViewTool(binding), createSkillAppendTool(binding)]
}

/**
 * Builds the read-only tool that exposes enabled skill content to the model.
 *
 * Skill files are wrapped as untrusted content because skills and agent append
 * files may come from repo/user-controlled sources, even though they are part of
 * the local library.
 */
function createSkillViewTool(binding: SkillToolsBinding): AgentTool<typeof SkillViewParams> {
  return buildTool({
    name: 'skill_view',
    label: 'Skill View',
    description:
      "Skills allow for loading information about specific tasks and workflows, as well as scripts and templates. Load a skill's full content or access its linked files (references, templates, scripts). Omit filePath to get the effective SKILL.md content; provide filePath to access a linked file.",
    schema: SkillViewParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params): Promise<AgentToolResult<unknown>> {
      const skill = await getEffectiveSkillContent({
        agentUid: binding.agentUid,
        skillName: params.name,
        filePath: params.filePath
      })
      if (!skill) {
        return {
          content: [{ type: 'text', text: `Skill or file not found or not enabled for this agent: ${params.name}` }],
          details: { found: false, name: params.name, filePath: params.filePath ?? 'SKILL.md' }
        }
      }
      return {
        content: [
          {
            type: 'text',
            text: `<skill name="${skill.name}" location="${skill.filePath}">\n${wrapExternalContent(skill.content, {
              source: 'skill',
              includeWarning: false
            })}\n</skill>`
          }
        ],
        details: { found: true, name: skill.name, filePath: skill.filePath, hasAgentAppend: skill.hasAgentAppend }
      }
    }
  })
}

/**
 * Builds the destructive tool that replaces an agent-specific AGENT_APPEND.md.
 */
function createSkillAppendTool(binding: SkillToolsBinding): AgentTool<typeof SkillAppendParams> {
  return buildTool({
    name: 'skill_append',
    label: 'Skill Append',
    description:
      "Replace this agent's AGENT_APPEND.md for an existing canonical skill. This customizes the skill for this agent without modifying the shared base SKILL.md.",
    schema: SkillAppendParams,
    executionMode: 'sequential',
    isDestructive: true,
    async execute(_toolCallId, params): Promise<AgentToolResult<unknown>> {
      await setAgentSkillAppend({ agentUid: binding.agentUid, skillName: params.name, content: params.content })
      return {
        content: [{ type: 'text', text: `Updated AGENT_APPEND.md for skill ${params.name}.` }],
        details: { name: params.name, path: `/workspace/library-containers/skills/${params.name}/AGENT_APPEND.md` }
      }
    }
  })
}
