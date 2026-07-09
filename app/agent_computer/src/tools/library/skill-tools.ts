import { join, normalize, resolve } from 'node:path'
import { readFile, realpath } from 'node:fs/promises'
import { z } from 'zod'
import type { ActorTurnRef } from '../../lanes/actor_lane'
import type { AgentTool, AgentToolResult } from '../../core'
import { jsonToolResult } from '../../core/tool-result'
import type {
  RuntimeSkillSummary,
  SkillOverlayReplaceRequest,
  SkillOverlayRequest,
  SkillOverlayResponse
} from '../../lanes/rpc_lane'

// `name` is the enabled skill name from RuntimeFabric. `filePath` lets the model
// follow references out of SKILL.md without a second tool, but resolution always
// stays inside the skill's source directory.
const SkillViewParams = z.object({
  name: z.string().min(1).describe('Enabled skill name to read.'),
  filePath: z.string().optional().describe('Skill-relative file path. Defaults to SKILL.md.')
})

const SkillAppendParams = z.object({
  name: z.string().min(1).describe('Enabled skill name whose agent notes should be updated.'),
  content: z.string().min(1).describe('New durable note text to append to this agent-specific skill overlay.')
})

/** Structured echo for logs/UI: which skill, which file, and (for append) whether it wrote. */
interface SkillToolDetails {
  name: string
  path?: string
  changed?: boolean
}

export const LONG_RUNNING_SKILL_ADDITION = [
  '---',
  'Ankole long-running skill discipline:',
  'After clarifying the request, do not run the execution phase inline. Tell the user the work is moving to the background, including the intended artifact and report path.',
  "Put durable artifacts under /workspace/user-files using this skill's own project layout. Start exactly one subagent delegation with a self-contained brief containing the specification, project path, this skill file location, quality gates, and completion criteria.",
  'Completion, failure, and questions wake the parent automatically; do not poll. Use check_back_later only for an intentional mid-task inspection of unusually long work.',
  'When awakened, personally verify the artifacts and checks, then deliver files with reply_attachment. The delegation id can always be recovered with subagent(list).'
].join('\n')

export type SkillOverlayRequester = (request: SkillOverlayRequest) => Promise<SkillOverlayResponse>
export type SkillOverlayReplaceRequester = (request: SkillOverlayReplaceRequest) => Promise<SkillOverlayResponse>

export interface SkillFileRoots {
  builtinSkillsRoot: string
  internalSkillsRoot?: string
  agentInstalledSkillsRoot: string
}

export interface CreateSkillToolsOptions {
  turn?: ActorTurnRef
  enabledSkills?: Array<RuntimeSkillSummary | string>
  skillRoots?: SkillFileRoots
  requestSkillOverlay?: SkillOverlayRequester
  replaceSkillOverlay?: SkillOverlayReplaceRequester
}

/**
 * Creates the skill tools available to the model.
 *
 * `skill_view` reads base skill files from their real source roots and resolves
 * the per-agent overlay over RuntimeFabric only for SKILL.md.
 * `skill_append` appends to that DB overlay over RuntimeFabric and does not write
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
 * It deliberately cannot enable a skill: a missing skill source surfaces as a
 * thrown read error, since enabling/assigning skills is a control-plane decision,
 * not something the model does.
 */
function createSkillViewTool(opts: CreateSkillToolsOptions): AgentTool<typeof SkillViewParams, SkillToolDetails> {
  return {
    name: 'skill_view',
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
      const skillRoot = skillFilesystemRoot(skill, opts)
      const absolute = await safeSkillPath(skillRoot, filePath)
      const content = await readFile(absolute, 'utf8')
      const rendered =
        filePath === 'SKILL.md'
          ? await renderEffectiveSkill(params.name, skillRoot, content, opts)
          : wrapSkillContent(params.name, skillLocation(params.name, filePath), skillRoot, content)
      return {
        content: [{ type: 'text', text: rendered }],
        details: { name: params.name, path: filePath }
      }
    }
  }
}

/**
 * `skill_append`: lets the agent persist durable notes onto a skill by appending
 * to the DB-backed overlay for that enabled skill. The base skill file stays
 * first-party or agent-installed filesystem content; only the overlay is mutable
 * here.
 */
function createSkillAppendTool(opts: CreateSkillToolsOptions): AgentTool<typeof SkillAppendParams, SkillToolDetails> {
  return {
    name: 'skill_append',
    description:
      "Append durable notes to this agent's DB-backed overlay for an enabled skill. Use only after reading the skill and only for agent-specific additions learned while using it.",
    schema: SkillAppendParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params): Promise<AgentToolResult<SkillToolDetails>> {
      enabledSkill(params.name, opts)
      if (!opts.turn || !opts.requestSkillOverlay || !opts.replaceSkillOverlay) {
        throw new Error('skill_append requires RuntimeFabric skill overlay RPC')
      }

      const appendedContent = appendOverlayText(await overlayText(params.name, opts), params.content)

      await opts.replaceSkillOverlay({
        request_id: `skill-overlay-replace-${crypto.randomUUID()}`,
        turn: opts.turn,
        skill_name: params.name,
        content: appendedContent,
        overlay_json: { text: appendedContent }
      })

      const details: SkillToolDetails = { name: params.name, changed: true }
      return jsonToolResult(details)
    }
  }
}

/**
 * Composes the skill the model actually sees: the base SKILL.md body (frontmatter
 * dropped — see {@link stripSkillFrontmatter}) followed by this agent's overlay, under a
 * labeled `Agent-specific additions` separator so the model can tell base SOP from the
 * agent's own notes. When no overlay exists the base is returned as-is.
 */
async function renderEffectiveSkill(
  name: string,
  directory: string,
  content: string,
  opts: CreateSkillToolsOptions
): Promise<string> {
  const baseContent = stripSkillFrontmatter(content)
  const overlayContent = await overlayText(name, opts)
  const withOverlay = overlayContent
    ? `${baseContent}\n\n---\nAgent-specific additions:\n\n${overlayContent}`
    : baseContent
  const skill = enabledSkill(name, opts)
  const effectiveContent =
    skill.metadata?.long_running === true ? `${withOverlay}\n\n${LONG_RUNNING_SKILL_ADDITION}` : withOverlay
  return wrapSkillContent(name, skillLocation(name, 'SKILL.md'), directory, effectiveContent)
}

/**
 * Resolves a skill-relative path to an absolute one and confines the file path
 * to the selected skill source directory.
 */
async function safeSkillPath(skillRoot: string, filePath: string): Promise<string> {
  const normalizedFilePath = normalizeSkillFilePath(filePath)
  const root = resolve(skillRoot)
  const resolved = resolve(root, normalizedFilePath)
  if (resolved !== root && !resolved.startsWith(`${root}/`)) {
    throw new Error('skill path escapes skill root')
  }

  const [realRoot, realResolved] = await Promise.all([realpath(root), realpath(resolved)])
  if (realResolved !== realRoot && !realResolved.startsWith(`${realRoot}/`)) {
    throw new Error('skill path escapes skill root through a symbolic link')
  }
  return realResolved
}

/**
 * Looks up an enabled skill by name and rejects disabled or invalid names.
 */
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

/**
 * Normalizes older string-only skill metadata into the current summary shape.
 */
function normalizeEnabledSkill(skill: RuntimeSkillSummary | string): RuntimeSkillSummary | undefined {
  if (typeof skill === 'string') {
    return isValidSkillName(skill) ? { skill_name: skill, source_kind: 'builtin', relative_path: skill } : undefined
  }

  return typeof skill.skill_name === 'string' && isValidSkillName(skill.skill_name) ? skill : undefined
}

/**
 * Resolves the filesystem root for a built-in or installed skill.
 */
function skillFilesystemRoot(skill: RuntimeSkillSummary, opts: CreateSkillToolsOptions): string {
  if (!opts.skillRoots) {
    throw new Error('skill_view requires worker skill source roots')
  }

  const relativePath = normalizeSkillRelativePath(skill.relative_path || skill.skill_name)
  const sourceKind = skill.source_kind || 'builtin'
  if (sourceKind === 'builtin') {
    const skillRoot = skillRootName(skill)
    if (skillRoot === 'internal') {
      if (!opts.skillRoots.internalSkillsRoot) {
        throw new Error(`internal skill root is not configured for builtin skill: ${skill.skill_name}`)
      }
      return join(opts.skillRoots.internalSkillsRoot, relativePath)
    }

    if (skillRoot && skillRoot !== 'library') {
      throw new Error(`unsupported builtin skill root ${skillRoot}: ${skill.skill_name}`)
    }

    return join(opts.skillRoots.builtinSkillsRoot, relativePath)
  }
  if (sourceKind === 'installed') {
    if (!opts.turn) throw new Error('installed skill_view requires an actor turn')
    return join(opts.skillRoots.agentInstalledSkillsRoot, opts.turn.actor.agent_uid, relativePath)
  }

  throw new Error(`unsupported skill source_kind: ${sourceKind}`)
}

function skillRootName(skill: RuntimeSkillSummary): string | undefined {
  if (typeof skill.skill_root === 'string' && skill.skill_root.length > 0) return skill.skill_root
  const metadataRoot = skill.metadata?.['skill_root']
  return typeof metadataRoot === 'string' && metadataRoot.length > 0 ? metadataRoot : undefined
}

/**
 * Throws when a skill name cannot be safely used as a skill identifier.
 */
function assertValidSkillName(name: string): void {
  if (!isValidSkillName(name)) {
    throw new Error('invalid skill name')
  }
}

/**
 * Checks the restricted skill-name syntax used in skill:// references.
 */
function isValidSkillName(name: string): boolean {
  return /^[a-z][a-z0-9_-]{0,63}$/.test(name)
}

/**
 * Normalizes a file path inside one skill source directory.
 */
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

/**
 * Normalizes the skill source directory path supplied by RuntimeFabric.
 */
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

/**
 * Builds the model-facing URI for an enabled skill file.
 */
function skillLocation(name: string, filePath: string): string {
  return `skill://enabled/${name}/${filePath}`
}

/**
 * Reads this agent's overlay text for one skill.
 */
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
 * Appends a new note to existing overlay text with a blank-line separator.
 */
function appendOverlayText(existing: string, addition: string): string {
  const note = addition.trim()
  if (!existing) return note
  if (!note) return existing
  return `${existing}\n\n${note}`
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
function wrapSkillContent(name: string, location: string, directory: string, content: string): string {
  return [
    `<skill name="${escapeAttribute(name)}" location="${escapeAttribute(location)}" directory="${escapeAttribute(directory)}">`,
    '<external_content source="skill">',
    content,
    '</external_content>',
    '</skill>'
  ].join('\n')
}

/**
 * Escapes values used in XML-like skill wrapper attributes.
 */
function escapeAttribute(value: string): string {
  return value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}
