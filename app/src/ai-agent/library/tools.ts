import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../core'
import { buildTool } from '../tools/build-tool'
import { getEffectiveSkillContent, searchEffectiveSkills, setAgentSkillAppend, setAgentSkillEnabled } from './service'

export interface SkillToolsBinding {
  agentUid: string
}

const SkillSearchParams = z.object({
  query: z.string().optional().describe('Task intent, skill name, category, or tag to search for.'),
  limit: z.number().int().min(1).max(50).optional().describe('Maximum number of skills to return.')
})

const SkillUseParams = z.object({
  name: z.string().min(1).describe('Skill name to load and use.'),
  filePath: z
    .string()
    .optional()
    .describe('Optional supporting file path relative to the skill directory, for example references/foo.md.')
})

const SkillAppendParams = z.object({
  name: z.string().min(1).describe('Skill name to customize for this agent.'),
  content: z.string().describe('Complete AGENT_APPEND.md content for this agent and skill.')
})

const SkillEnableParams = z.object({
  name: z.string().min(1).describe('Skill name to enable or disable for this agent.'),
  enabled: z.boolean().describe('true to enable for this agent, false to disable for this agent.'),
  reason: z.string().optional().describe('Short reason for the override.')
})

export function createSkillTools(binding: SkillToolsBinding): AgentTool<any>[] {
  return [createSkillSearchTool(binding), createSkillUseTool(binding), createSkillAppendTool(binding), createSkillEnableTool(binding)]
}

function createSkillSearchTool(binding: SkillToolsBinding): AgentTool<typeof SkillSearchParams> {
  return buildTool({
    name: 'skill_search',
    label: 'Skill Search',
    description:
      'Search the skills currently enabled for this agent. Use this before specialized work when a skill may contain relevant local instructions.',
    schema: SkillSearchParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params): Promise<AgentToolResult<unknown>> {
      const skills = await searchEffectiveSkills({ agentUid: binding.agentUid, query: params.query, limit: params.limit })
      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify(
              skills.map(skill => ({
                name: skill.name,
                description: skill.description,
                tags: skill.tags,
                category: skill.category,
                location: `/workspace/library-containers/skills/${skill.name}/SKILL.md`,
                has_agent_append: skill.hasAgentAppend
              })),
              null,
              2
            )
          }
        ],
        details: { count: skills.length, skills }
      }
    }
  })
}

function createSkillUseTool(binding: SkillToolsBinding): AgentTool<typeof SkillUseParams> {
  return buildTool({
    name: 'skill_use',
    label: 'Skill Use',
    description:
      'Load a skill for the current task. Without filePath, returns the effective SKILL.md instructions merged with this agent\'s AGENT_APPEND.md. With filePath, returns a supporting file.',
    schema: SkillUseParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params): Promise<AgentToolResult<unknown>> {
      const skill = await getEffectiveSkillContent({ agentUid: binding.agentUid, skillName: params.name, filePath: params.filePath })
      if (!skill) {
        return {
          content: [{ type: 'text', text: `Skill or file not found or not enabled for this agent: ${params.name}` }],
          details: { found: false, name: params.name, filePath: params.filePath ?? 'SKILL.md' }
        }
      }
      return {
        content: [{ type: 'text', text: `<skill name="${skill.name}" location="${skill.filePath}">\n${skill.content}\n</skill>` }],
        details: { found: true, name: skill.name, filePath: skill.filePath, hasAgentAppend: skill.hasAgentAppend }
      }
    }
  })
}

function createSkillAppendTool(binding: SkillToolsBinding): AgentTool<typeof SkillAppendParams> {
  return buildTool({
    name: 'skill_append',
    label: 'Skill Append',
    description:
      'Replace this agent\'s AGENT_APPEND.md for an existing canonical skill. This customizes the skill for this agent without modifying the shared base SKILL.md.',
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

function createSkillEnableTool(binding: SkillToolsBinding): AgentTool<typeof SkillEnableParams> {
  return buildTool({
    name: 'skill_enable',
    label: 'Skill Enable',
    description: 'Enable or disable an existing canonical skill for this agent. Disabling affects only this agent.',
    schema: SkillEnableParams,
    executionMode: 'sequential',
    isDestructive: true,
    async execute(_toolCallId, params): Promise<AgentToolResult<unknown>> {
      await setAgentSkillEnabled({ agentUid: binding.agentUid, skillName: params.name, enabled: params.enabled, reason: params.reason })
      return {
        content: [{ type: 'text', text: `${params.enabled ? 'Enabled' : 'Disabled'} skill ${params.name} for this agent.` }],
        details: { name: params.name, enabled: params.enabled }
      }
    }
  })
}
