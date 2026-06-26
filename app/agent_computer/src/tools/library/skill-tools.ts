import { readFileSync } from 'node:fs'
import { join, normalize, resolve } from 'node:path'
import { z } from 'zod'
import type { ActorTurnRef } from '../../actor_lane'
import type { AgentTool, AgentToolResult } from '../../core'
import type {
  RuntimeSkillSummary,
  SkillOverlayReplaceRequest,
  SkillOverlayRequest,
  SkillOverlayResponse
} from '../../rpc_lane'
import { buildTool } from '../build-tool'

// `name` is the enabled skill name from RuntimeFabric. `filePath` lets the model
// follow references out of SKILL.md without a second tool, but resolution always
// stays inside the skill's source directory.
const SkillViewParams = z.object({
  name: z.string().min(1).describe('Enabled skill name to read.'),
  filePath: z.string().optional().describe('Skill-relative file path. Defaults to SKILL.md.')
})

// `content` is a full DB overlay replacement, not a file append despite the tool name.
// The tool name is kept for model/tool migration safety.
const SkillAppendParams = z.object({
  name: z.string().min(1).describe('Enabled skill name whose agent overlay should be replaced.'),
  content: z.string().describe('Full replacement content for the agent-specific skill overlay.')
})

/** Structured echo for logs/UI: which skill, which file, and (for append) whether it wrote. */
interface SkillToolDetails {
  name: string
  path?: string
  changed?: boolean
}

export type SkillOverlayRequester = (request: SkillOverlayRequest) => Promise<SkillOverlayResponse>
export type SkillOverlayReplaceRequester = (request: SkillOverlayReplaceRequest) => Promise<SkillOverlayResponse>

export interface SkillFileRoots {
  builtinSkillsRoot: string
  agentInstalledSkillsRoot: string
}

export interface CreateSkillToolsOptions {
  turn?: ActorTurnRef
  enabledSkills?: Array<RuntimeSkillSummary | string>
  skillRoots?: SkillFileRoots
  requestSkillOverlay?: SkillOverlayRequester
  replaceSkillOverlay?: SkillOverlayReplaceRequester
  clearSkillOverlay?: SkillOverlayRequester
}

/**
 * Creates the skill tools available to the model.
 *
 * `skill_view` reads base skill files from their real source roots and resolves
 * the per-agent overlay over RuntimeFabric only for SKILL.md.
 * `skill_append` replaces that DB overlay over RuntimeFabric and does not write
 * any workspace file. Assignment remains a control-plane concern.
 */
export function createSkillTools(_workspaceRoot: string, opts: CreateSkillToolsOptions = {}): AgentTool<any>[] {
  return [createSkillViewTool(opts), createSkillAppendTool(opts)]
}

/**
 * `skill_view`: loads a skill's instructions on demand. The system prompt only lists
 * skills as an index (name + one-line description); when the model decides a listed
 * skill covers the task it is about to do, it calls this to pull in the full SOP.
 *
 * Read-only and `parallel` because it only reads immutable or managed skill source
 * files — several skills can be loaded at once. It deliberately cannot enable a
 * skill: a missing skill source surfaces as a thrown read error, since
 * enabling/assigning skills is a control-plane decision, not something the model does.
 */
function createSkillViewTool(opts: CreateSkillToolsOptions): AgentTool<typeof SkillViewParams, SkillToolDetails> {
  return buildTool({
    name: 'skill_view',
    label: 'Skill View',
    description:
      'Read an enabled skill file. Use SKILL.md first; read referenced files only when needed. This tool cannot enable disabled skills.',
    schema: SkillViewParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params): Promise<AgentToolResult<SkillToolDetails>> {
      const filePath = normalizeSkillFilePath(params.filePath ?? 'SKILL.md')
      const skill = enabledSkill(params.name, opts)
      if (filePath === 'AGENT_APPEND.md') {
        throw new Error('skill overlays are DB-backed semantic data, not AGENT_APPEND.md files')
      }
      const absolute = safeSkillPath(skillFilesystemRoot(skill, opts), filePath)
      const content = readFileSync(absolute, 'utf8')
      const rendered =
        filePath === 'SKILL.md'
          ? await renderEffectiveSkill(params.name, content, opts)
          : wrapSkillContent(params.name, skillLocation(params.name, filePath), content)
      return {
        content: [{ type: 'text', text: rendered }],
        details: { name: params.name, path: filePath }
      }
    }
  })
}

/**
 * `skill_append`: lets the agent persist durable notes onto a skill by replacing the
 * DB-backed overlay for that enabled skill. The base skill file stays first-party or
 * agent-installed filesystem content; only the overlay is mutable here.
 */
function createSkillAppendTool(opts: CreateSkillToolsOptions): AgentTool<typeof SkillAppendParams, SkillToolDetails> {
  return buildTool({
    name: 'skill_append',
    label: 'Skill Append',
    description:
      "Replace this agent's DB-backed overlay for an enabled skill. Use only after reading the skill and only for durable agent-specific additions.",
    schema: SkillAppendParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    async execute(_toolCallId, params): Promise<AgentToolResult<SkillToolDetails>> {
      enabledSkill(params.name, opts)
      if (!opts.turn || !opts.replaceSkillOverlay) {
        throw new Error('skill_append requires RuntimeFabric skill overlay RPC')
      }

      await opts.replaceSkillOverlay({
        request_id: `skill-overlay-replace-${crypto.randomUUID()}`,
        turn: opts.turn,
        skill_name: params.name,
        content: params.content,
        overlay_json: { text: params.content }
      })

      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify({ name: params.name, changed: true })
          }
        ],
        details: { name: params.name, changed: true }
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
async function renderEffectiveSkill(name: string, content: string, opts: CreateSkillToolsOptions): Promise<string> {
  const baseContent = stripSkillFrontmatter(content)
  const overlayContent = await overlayText(name, opts)
  const effectiveContent = overlayContent
    ? `${baseContent}\n\n---\nAgent-specific additions:\n\n${overlayContent}`
    : baseContent
  return wrapSkillContent(name, skillLocation(name, 'SKILL.md'), effectiveContent)
}

/**
 * Resolves a skill-relative path to an absolute one and confines the file path
 * to the selected skill source directory.
 */
function safeSkillPath(skillRoot: string, filePath: string): string {
  const normalizedFilePath = normalizeSkillFilePath(filePath)
  const root = resolve(skillRoot)
  const resolved = resolve(root, normalizedFilePath)
  if (resolved !== root && !resolved.startsWith(`${root}/`)) {
    throw new Error('skill path escapes skill root')
  }
  return resolved
}

function enabledSkill(name: string, opts: CreateSkillToolsOptions): RuntimeSkillSummary {
  assertValidSkillName(name)
  if (!opts.enabledSkills) {
    throw new Error('skill tools require RuntimeFabric enabled skill metadata')
  }

  const skill = opts.enabledSkills.map(normalizeEnabledSkill).find(candidate => candidate?.skill_name === name)

  if (!skill) {
    throw new Error(`skill is not enabled for this turn: ${name}`)
  }

  return skill
}

function normalizeEnabledSkill(skill: RuntimeSkillSummary | string): RuntimeSkillSummary | undefined {
  if (typeof skill === 'string') {
    return isValidSkillName(skill) ? { skill_name: skill, source_kind: 'builtin', relative_path: skill } : undefined
  }

  return typeof skill.skill_name === 'string' && isValidSkillName(skill.skill_name) ? skill : undefined
}

function skillFilesystemRoot(skill: RuntimeSkillSummary, opts: CreateSkillToolsOptions): string {
  if (!opts.skillRoots) {
    throw new Error('skill_view requires worker skill source roots')
  }

  const relativePath = normalizeSkillRelativePath(skill.relative_path || skill.skill_name)
  const sourceKind = skill.source_kind || 'builtin'
  if (sourceKind === 'builtin') {
    return join(opts.skillRoots.builtinSkillsRoot, relativePath)
  }
  if (sourceKind === 'installed') {
    if (!opts.turn) throw new Error('installed skill_view requires an actor turn')
    return join(opts.skillRoots.agentInstalledSkillsRoot, opts.turn.actor.agent_uid, relativePath)
  }

  throw new Error(`unsupported skill source_kind: ${sourceKind}`)
}

function assertValidSkillName(name: string): void {
  if (!isValidSkillName(name)) {
    throw new Error('invalid skill name')
  }
}

function isValidSkillName(name: string): boolean {
  return /^[a-z][a-z0-9_-]{0,63}$/.test(name)
}

function normalizeSkillFilePath(filePath: string): string {
  const raw = filePath.replaceAll('\\', '/')
  if (raw.split('/').some(segment => segment === '..')) {
    throw new Error('invalid skill file path')
  }
  const normalized = normalize(raw).replaceAll('\\', '/')
  if (
    normalized.length === 0 ||
    normalized.startsWith('../') ||
    normalized === '..' ||
    normalized.startsWith('/') ||
    normalized.split('/').some(segment => segment === '' || segment === '.' || segment === '..')
  ) {
    throw new Error('invalid skill file path')
  }
  return normalized
}

function normalizeSkillRelativePath(relativePath: string): string {
  const normalized = relativePath.replaceAll('\\', '/').replace(/^\/+/, '').replace(/\/+/g, '/')
  if (
    normalized.length === 0 ||
    normalized === '.' ||
    normalized === '..' ||
    normalized.split('/').some(segment => segment === '' || segment === '.' || segment === '..')
  ) {
    throw new Error(`invalid skill relative_path: ${relativePath}`)
  }
  return normalized
}

function skillLocation(name: string, filePath: string): string {
  return `skill://enabled/${name}/${filePath}`
}

async function overlayText(name: string, opts: CreateSkillToolsOptions): Promise<string> {
  if (!opts.turn || !opts.requestSkillOverlay) return ''

  const response = await opts.requestSkillOverlay({
    request_id: `skill-overlay-resolve-${crypto.randomUUID()}`,
    turn: opts.turn,
    skill_name: name
  })
  const text = response.overlay_json?.text
  return typeof text === 'string' ? text.trim() : ''
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
