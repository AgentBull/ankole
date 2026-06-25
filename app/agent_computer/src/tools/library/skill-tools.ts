import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, normalize, resolve } from 'node:path'
import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'

// `name` is the directory name under library-containers/skills; "enabled" means the
// control plane already projected that skill into this workspace. `filePath` lets the
// model follow references out of SKILL.md (e.g. a `reference.md` the skill links to)
// without a second tool — but it is always resolved *inside* the skill's own directory.
const SkillViewParams = z.object({
  name: z.string().min(1).describe('Enabled skill name to read.'),
  filePath: z.string().optional().describe('Skill-relative file path. Defaults to SKILL.md.')
})

// `content` is a *full replacement* of the overlay, not an append despite the tool name:
// the model resends the entire desired AGENT_APPEND.md each time, so a write is
// idempotent and there is no read-modify-write step that could race or drift.
const SkillAppendParams = z.object({
  name: z.string().min(1).describe('Enabled skill name whose agent overlay should be replaced.'),
  content: z.string().describe('Full replacement content for AGENT_APPEND.md.')
})

/** Structured echo for logs/UI: which skill, which file, and (for append) whether it wrote. */
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

/**
 * `skill_view`: loads a skill's instructions on demand. The system prompt only lists
 * skills as an index (name + one-line description); when the model decides a listed
 * skill covers the task it is about to do, it calls this to pull in the full SOP.
 *
 * Read-only and `parallel` because it only reads projected files — several skills can
 * be loaded at once. It deliberately cannot enable a skill: a missing skill directory
 * surfaces as a thrown read error (which the loop relays back to the model), since
 * enabling/assigning skills is a control-plane decision, not something the model does.
 */
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
      // Reading the skill's entry file (SKILL.md) returns the *effective* skill: base
      // instructions with the agent's overlay merged in. Any other referenced file is
      // returned verbatim — only the entry point carries the per-agent additions.
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

/**
 * `skill_append`: lets the agent persist its own durable notes onto a skill by writing
 * the skill's `AGENT_APPEND.md` overlay. This is how an agent customizes a shared,
 * control-plane-owned skill without editing the skill itself — the base SKILL.md stays
 * pristine while the overlay is per-agent and survives across conversations.
 *
 * The filename is hardcoded to `AGENT_APPEND.md` (the model picks the skill, never the
 * filename), so within a skill dir it can only write the overlay, not other skill files —
 * though see `safeSkillPath` for the `name`-traversal caveat on *which* dir that is.
 * Destructive/sequential because it overwrites that file. `mkdirSync` is defensive: a
 * projected skill dir should exist, but the overlay's parent is ensured before the first
 * write either way.
 */
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

/**
 * Composes the skill the model actually sees: the base SKILL.md body (frontmatter
 * dropped — see {@link stripSkillFrontmatter}) followed by this agent's overlay, under a
 * labeled `Agent-specific additions` separator so the model can tell base SOP from the
 * agent's own notes. When no overlay exists the base is returned as-is.
 */
function renderEffectiveSkill(workspaceRoot: string, name: string, content: string): string {
  const baseContent = stripSkillFrontmatter(content)
  const appendPath = safeSkillPath(workspaceRoot, name, 'AGENT_APPEND.md')
  const appendContent = existsSync(appendPath) ? readFileSync(appendPath, 'utf8').trim() : ''
  const effectiveContent = appendContent
    ? `${baseContent}\n\n---\nAgent-specific additions:\n\n${appendContent}`
    : baseContent
  return wrapSkillContent(name, `/workspace/library-containers/skills/${name}/SKILL.md`, effectiveContent)
}

/**
 * Resolves a skill-relative path to an absolute one and confines `filePath` to the
 * skill's own directory. The `escapes skill root` guard only covers `filePath`: it builds
 * `skillRoot` from `name`, resolves `filePath` against it, and rejects the result if it
 * climbs back out — so a `filePath` like `../../etc/passwd` is blocked.
 *
 * It does NOT confine `name`. Since the boundary is derived from `name`, a `name`
 * containing `../` relocates `skillRoot` instead of tripping the check, and `name` is
 * unvalidated model input (the schema is only `z.string().min(1)`). So this function
 * hardens the file path but not the skill id — treat it as a filePath guard, not a full
 * traversal guard.
 * TODO: also confine `name` (or validate it against the enabled-skill set) so a crafted
 * skill name cannot read/write outside the skills container.
 */
function safeSkillPath(workspaceRoot: string, name: string, filePath: string): string {
  const root = resolve(workspaceRoot)
  const skillRoot = resolve(root, 'library-containers/skills', name)
  const resolved = resolve(skillRoot, normalize(filePath))
  if (resolved !== skillRoot && !resolved.startsWith(`${skillRoot}/`)) {
    throw new Error('skill path escapes skill root')
  }
  return resolved
}

/**
 * Drops the YAML frontmatter block from a SKILL.md body. The frontmatter (name,
 * description, category) is catalog metadata already surfaced in the prompt index, so
 * it is noise once the model is reading the full skill. A file with no leading `---` is
 * returned trimmed and unchanged.
 */
function stripSkillFrontmatter(content: string): string {
  if (!content.startsWith('---')) return content.trim()
  const match = /^---\r?\n[\s\S]*?\r?\n---\r?\n?([\s\S]*)$/.exec(content)
  return (match?.[1] ?? content).trim()
}

/**
 * Wraps skill text in `<skill><external_content>` tags before handing it to the model.
 * The `external_content` marker tells the model this is reference material it loaded, not
 * its own instructions or the user's words; `name`/`location` are attribute-escaped since
 * a skill name could otherwise break out of the tag.
 */
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
