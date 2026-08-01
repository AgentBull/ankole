import { normalize, resolve } from 'node:path'
import { readFile, realpath } from 'node:fs/promises'
import { z } from 'zod'
import type { ActorTurnRef } from '../../lanes/actor_lane'
import type { AgentTool, AgentToolResult } from '../../core'
import { jsonToolResult } from '../../core/tool-result'
import { jsonBytes } from '../../fabric/envelope_proto'
import { rpcMethods, type RPCRequester, type RuntimeSkillSummary } from '../../lanes/rpc_lane'
import {
  ankoleSkillRuntime,
  enabledSkillByName,
  resolveSkillFilesystemRoot,
  resolveSkillOverlayText,
  stripSkillFrontmatter,
  type SkillFileRoots
} from '../../skills/effective-skill'

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

const SkillReplaceParams = z.object({
  name: z.string().min(1).describe('Enabled skill name whose agent notes should be replaced.'),
  content: z.string().describe('Complete replacement text for this agent-specific skill overlay.')
})

/** Structured echo for logs/UI: which skill, which file, and (for append) whether it wrote. */
interface SkillToolDetails {
  name: string
  path?: string
  changed?: boolean
}

export type { SkillFileRoots } from '../../skills/effective-skill'

export interface CreateSkillToolsOptions {
  turn: ActorTurnRef
  enabledSkills?: Array<RuntimeSkillSummary | string>
  skillRoots?: SkillFileRoots
  rpc: RPCRequester
}

/**
 * Creates the skill tools available to the model.
 *
 * `skill_view` reads base skill files from their real source roots and resolves
 * the per-agent overlay over RuntimeFabric only for SKILL.md.
 * `skill_append` appends to that DB overlay over RuntimeFabric and does not write
 * any workspace file. Assignment remains a control-plane concern.
 */
export function createSkillTools(_workspaceRoot: string, opts: CreateSkillToolsOptions): AgentTool<any>[] {
  return [createSkillViewTool(opts), createSkillAppendTool(opts), createSkillReplaceTool(opts)]
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
      'Read an enabled inline skill file. For a Skill with ankole-runtime: background_job, this returns only background agent job routing guidance and rejects referenced resources. For inline Skills, read referenced files only when needed, resolve relative paths from the returned skill directory, and use absolute paths for tool calls. This tool cannot enable disabled skills.',
    schema: SkillViewParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: params => `加载 Skill：${params.name}`,
    async execute(_toolCallId, params): Promise<AgentToolResult<SkillToolDetails>> {
      const filePath = normalizeSkillFilePath(params.filePath ?? 'SKILL.md')
      const skill = enabledSkill(params.name, opts)
      if (filePath === 'AGENT_APPEND.md') {
        throw new Error('skill overlays are DB-backed semantic data, not AGENT_APPEND.md files')
      }
      const skillRoot = skillFilesystemRoot(skill, opts)
      if (ankoleSkillRuntime(skill) === 'background_job') {
        if (filePath !== 'SKILL.md') {
          throw new Error(
            `background-job-only Skill resources are available only inside a background agent job; create one with create_background_job and name ${params.name} in its task`
          )
        }
        await safeSkillPath(skillRoot, 'SKILL.md')
        return {
          content: [{ type: 'text', text: backgroundJobSkillDispatchContent(params.name) }],
          details: { name: params.name, path: filePath }
        }
      }
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
 * `skill_append`: atomically adds one durable note to the DB-backed overlay. The
 * control plane owns the read-modify-write transaction so concurrent turns do
 * not lose each other's additions.
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
    describeActivity: params => `更新 Skill：${params.name}`,
    async execute(_toolCallId, params): Promise<AgentToolResult<SkillToolDetails>> {
      enabledInlineSkillForOverlay(params.name, opts)
      await opts.rpc(
        rpcMethods.skillsOverlayAppend,
        { skillName: params.name, content: params.content },
        { turn: opts.turn }
      )

      const details: SkillToolDetails = { name: params.name, changed: true }
      return jsonToolResult(details)
    }
  }
}

/**
 * Replaces the complete overlay using the latest resolved content hash as an
 * optimistic compare-and-swap fence. A concurrent writer causes the control
 * plane to reject the replacement instead of silently losing an update.
 */
function createSkillReplaceTool(opts: CreateSkillToolsOptions): AgentTool<typeof SkillReplaceParams, SkillToolDetails> {
  return {
    name: 'skill_replace',
    description:
      "Replace all durable notes in this agent's DB-backed overlay for an enabled skill. Read the skill first, then use this for revisions, deduplication, or budget-preserving compaction; a concurrent change is rejected.",
    schema: SkillReplaceParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    describeActivity: params => `更新 Skill：${params.name}`,
    async execute(_toolCallID, params): Promise<AgentToolResult<SkillToolDetails>> {
      enabledInlineSkillForOverlay(params.name, opts)
      const current = await opts.rpc(rpcMethods.skillsOverlayResolve, { skillName: params.name }, { turn: opts.turn })
      await opts.rpc(
        rpcMethods.skillsOverlayReplace,
        {
          skillName: params.name,
          content: params.content,
          overlayJson: jsonBytes({ text: params.content }),
          expectedContentHash: current.contentHash
        },
        { turn: opts.turn }
      )

      return jsonToolResult({ name: params.name, changed: true })
    }
  }
}

/**
 * Composes the inline skill the model actually sees: the base SKILL.md body (frontmatter
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
  return wrapSkillContent(name, skillLocation(name, 'SKILL.md'), directory, withOverlay)
}

/**
 * Returns only main-agent routing guidance for a background-job-only Skill. Its full
 * operational body, references, and overlay remain available to Codex when the
 * BackgroundAgentJob runtime materializes the enabled Skill directory.
 */
function backgroundJobSkillDispatchContent(name: string): string {
  return [
    `The enabled ${name} Skill is a background-task capability.`,
    'Do not execute it inline and do not try to read its operational body or referenced resources from the main agent.',
    `Create a background agent job with create_background_job. Put the complete user request, constraints, paths, acceptance criteria, and an explicit instruction to use the ${name} Skill in the task.`,
    'The background agent job receives the complete enabled Skill directory and can read its instructions and resources there.'
  ].join('\n')
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
  return enabledSkillByName(name, opts.enabledSkills)
}

/** Rejects main-agent overlay writes for Skills whose complete contract belongs to a Job. */
function enabledInlineSkillForOverlay(name: string, opts: CreateSkillToolsOptions): RuntimeSkillSummary {
  const skill = enabledSkill(name, opts)
  if (ankoleSkillRuntime(skill) === 'background_job') {
    throw new Error(`background-job Skill overlays are available only inside a background agent job: ${name}`)
  }
  return skill
}

/**
 * Resolves the filesystem root for a built-in or installed skill.
 */
function skillFilesystemRoot(skill: RuntimeSkillSummary, opts: CreateSkillToolsOptions): string {
  if (!opts.skillRoots) {
    throw new Error('skill_view requires worker skill source roots')
  }

  return resolveSkillFilesystemRoot(skill, { skillRoots: opts.skillRoots })
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
 * Builds the model-facing URI for an enabled skill file.
 */
function skillLocation(name: string, filePath: string): string {
  return `skill://enabled/${name}/${filePath}`
}

/**
 * Reads this agent's overlay text for one skill.
 */
async function overlayText(name: string, opts: CreateSkillToolsOptions): Promise<string> {
  return await resolveSkillOverlayText(name, opts)
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
