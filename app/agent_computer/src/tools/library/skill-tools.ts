import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, normalize, resolve } from 'node:path'
import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'

const SkillViewParams = z.object({
  name: z.string().min(1).describe('Enabled skill name to read.'),
  filePath: z.string().optional().describe('Skill-relative file path. Defaults to SKILL.md.')
})

const SkillAppendParams = z.object({
  name: z.string().min(1).describe('Enabled skill name whose agent overlay should be replaced.'),
  content: z.string().describe('Full replacement content for AGENT_APPEND.md.')
})

interface SkillToolDetails {
  name: string
  path?: string
  changed?: boolean
}

/**
 * Creates the skill tools available to the model.
 *
 * `skill_view` reads only from the projected library container. `skill_append`
 * writes the agent-local overlay file that is already part of the projected
 * library state. There is intentionally no enable/disable tool in this main
 * chain; assignment remains a control-plane concern.
 */
export function createSkillTools(workspaceRoot: string): AgentTool<any>[] {
  return [createSkillViewTool(workspaceRoot), createSkillAppendTool(workspaceRoot)]
}

function createSkillViewTool(workspaceRoot: string): AgentTool<typeof SkillViewParams, SkillToolDetails> {
  return buildTool({
    name: 'skill_view',
    label: 'Skill View',
    description:
      'Read an enabled skill file from /workspace/library-containers/skills. Use SKILL.md first; read referenced files only when needed. This tool cannot enable disabled skills.',
    schema: SkillViewParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params): Promise<AgentToolResult<SkillToolDetails>> {
      const filePath = params.filePath ?? 'SKILL.md'
      const absolute = safeSkillPath(workspaceRoot, params.name, filePath)
      const content = readFileSync(absolute, 'utf8')
      const rendered =
        filePath === 'SKILL.md'
          ? renderEffectiveSkill(workspaceRoot, params.name, content)
          : wrapSkillContent(params.name, `/workspace/library-containers/skills/${params.name}/${filePath}`, content)
      return {
        content: [{ type: 'text', text: rendered }],
        details: { name: params.name, path: filePath }
      }
    }
  })
}

function createSkillAppendTool(workspaceRoot: string): AgentTool<typeof SkillAppendParams, SkillToolDetails> {
  return buildTool({
    name: 'skill_append',
    label: 'Skill Append',
    description:
      "Replace this agent's AGENT_APPEND.md overlay for an enabled skill. Use only after reading the skill and only for durable agent-specific additions.",
    schema: SkillAppendParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    async execute(_toolCallId, params): Promise<AgentToolResult<SkillToolDetails>> {
      const absolute = safeSkillPath(workspaceRoot, params.name, 'AGENT_APPEND.md')
      mkdirSync(dirname(absolute), { recursive: true })
      writeFileSync(absolute, params.content)
      return {
        content: [{ type: 'text', text: JSON.stringify({ name: params.name, changed: true }) }],
        details: { name: params.name, path: 'AGENT_APPEND.md', changed: true }
      }
    }
  })
}

function renderEffectiveSkill(workspaceRoot: string, name: string, content: string): string {
  const baseContent = stripSkillFrontmatter(content)
  const appendPath = safeSkillPath(workspaceRoot, name, 'AGENT_APPEND.md')
  const appendContent = existsSync(appendPath) ? readFileSync(appendPath, 'utf8').trim() : ''
  const effectiveContent = appendContent
    ? `${baseContent}\n\n---\nAgent-specific additions:\n\n${appendContent}`
    : baseContent
  return wrapSkillContent(name, `/workspace/library-containers/skills/${name}/SKILL.md`, effectiveContent)
}

function safeSkillPath(workspaceRoot: string, name: string, filePath: string): string {
  const root = resolve(workspaceRoot)
  const skillRoot = resolve(root, 'library-containers/skills', name)
  const resolved = resolve(skillRoot, normalize(filePath))
  if (resolved !== skillRoot && !resolved.startsWith(`${skillRoot}/`)) {
    throw new Error('skill path escapes skill root')
  }
  return resolved
}

function stripSkillFrontmatter(content: string): string {
  if (!content.startsWith('---')) return content.trim()
  const match = /^---\r?\n[\s\S]*?\r?\n---\r?\n?([\s\S]*)$/.exec(content)
  return (match?.[1] ?? content).trim()
}

function wrapSkillContent(name: string, location: string, content: string): string {
  return [
    `<skill name="${escapeAttribute(name)}" location="${escapeAttribute(location)}">`,
    '<external_content source="skill">',
    content,
    '</external_content>',
    '</skill>'
  ].join('\n')
}

function escapeAttribute(value: string): string {
  return value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}
