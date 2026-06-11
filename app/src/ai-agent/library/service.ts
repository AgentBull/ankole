import { genUUIDv7, genericHash } from '@agentbull/bullx-native-addons'
import { and, asc, eq, inArray, isNull, notInArray, sql } from 'drizzle-orm'
import { readdir } from 'node:fs/promises'
import path from 'node:path'
import { DB, jsonbParam, type QueryExecutor } from '@/common/database'
import { logger } from '@/common/logger'
import {
  AgentLibraryContainerEntries,
  AgentSkillAssignments,
  LibraryBuiltinSyncState,
  LibrarySkillFiles,
  LibrarySkills,
  type JsonObject
} from '@/common/db-schema'
import { parseSkillFile, type Skill } from '../core'
import {
  APP_SKILLS_ROOT,
  INTERNALS_SKILLS_ROOT,
  loadDefaultMissionTemplate,
  loadDefaultSoulTemplate
} from './default-soul'
import { auditSkillAppendContent, type SkillContentDiagnostic } from './skill-guard'

const SYNC_KEY = 'app+internals/library/skills'
const SKILL_FILE = 'SKILL.md'
const AGENT_APPEND_FILE = 'AGENT_APPEND.md'
const SOUL_FILE = 'SOUL.md'
const MISSION_FILE = 'MISSION.md'
const SKILL_SYNC_IGNORE_FILE = '.skill-sync-ignore'

const BUILTIN_SKILL_ROOTS = [
  { label: 'app', root: APP_SKILLS_ROOT },
  { label: 'internals', root: INTERNALS_SKILLS_ROOT }
] as const

export interface LibrarySyncResult {
  changed: boolean
  contentHash: string
  diagnostics: LibrarySkillDiagnostic[]
  skills: number
  files: number
}

export interface LibrarySkillDiagnostic {
  code: string
  message: string
  path: string
  severity: 'error' | 'warning'
}

export interface EffectiveSkillSummary {
  id: string
  name: string
  description: string
  defaultEnabled: boolean
  enabled: boolean
  sourceKind: string
  rootPath: string
  tags: string[]
  category?: string
  metadata: JsonObject
  hasAgentAppend: boolean
}

export interface EffectiveSkillContent extends EffectiveSkillSummary {
  filePath: string
  content: string
  baseContent?: string
  appendContent?: string
}

export interface LibraryContainerFile {
  content: string
  virtualPath: string
}

interface BuiltinSkillSource {
  name: string
  description: string
  defaultEnabled: boolean
  rootPath: string
  metadata: JsonObject
  sourceHash: string
  sourceRoot: string
  files: Array<{ virtualPath: string; content: string; sha: string }>
}

export async function syncBuiltinLibraryFromAppDirectory(
  options: { force?: boolean } = {}
): Promise<LibrarySyncResult> {
  const { sources, diagnostics } = await readBuiltinSkillSources()
  const contentHash = stableHash(
    sources.flatMap(skill => [
      skill.name,
      skill.sourceHash,
      ...skill.files.map(file => `${file.virtualPath}:${file.sha}`)
    ])
  )

  const [state] = await DB.select()
    .from(LibraryBuiltinSyncState)
    .where(eq(LibraryBuiltinSyncState.syncKey, SYNC_KEY))
    .limit(1)
  if (!options.force && state?.contentHash === contentHash) {
    return {
      changed: false,
      contentHash,
      diagnostics,
      skills: sources.length,
      files: sources.reduce((sum, skill) => sum + skill.files.length, 0)
    }
  }

  await DB.transaction(async tx => {
    const seenNames = sources.map(skill => skill.name)
    if (seenNames.length > 0) {
      await tx
        .update(LibrarySkills)
        .set({ enabled: false, archivedAt: sql`now()`, updatedAt: sql`now()` })
        .where(and(eq(LibrarySkills.sourceKind, 'builtin'), notInArray(LibrarySkills.name, seenNames)))
    } else {
      await tx
        .update(LibrarySkills)
        .set({ enabled: false, archivedAt: sql`now()`, updatedAt: sql`now()` })
        .where(eq(LibrarySkills.sourceKind, 'builtin'))
    }

    for (const source of sources) {
      const skillId = genUUIDv7()
      const [skill] = await tx
        .insert(LibrarySkills)
        .values({
          id: skillId,
          name: source.name,
          description: source.description,
          defaultEnabled: source.defaultEnabled,
          enabled: true,
          sourceKind: 'builtin',
          sourceHash: source.sourceHash,
          rootPath: source.rootPath,
          metadata: jsonbParam(source.metadata),
          archivedAt: null,
          updatedAt: sql`now()`
        })
        .onConflictDoUpdate({
          target: LibrarySkills.name,
          set: {
            description: source.description,
            defaultEnabled: source.defaultEnabled,
            enabled: true,
            sourceKind: 'builtin',
            sourceHash: source.sourceHash,
            rootPath: source.rootPath,
            metadata: jsonbParam(source.metadata),
            archivedAt: null,
            updatedAt: sql`now()`
          }
        })
        .returning()

      await tx.delete(LibrarySkillFiles).where(eq(LibrarySkillFiles.skillId, skill.id))
      if (source.files.length > 0) {
        await tx.insert(LibrarySkillFiles).values(
          source.files.map(file => ({
            id: genUUIDv7(),
            skillId: skill.id,
            virtualPath: file.virtualPath,
            contentText: file.content,
            contentBlake3: file.sha,
            contentMediaType: mediaTypeForPath(file.virtualPath),
            metadata: jsonbParam({})
          }))
        )
      }
    }

    await tx
      .insert(LibraryBuiltinSyncState)
      .values({
        syncKey: SYNC_KEY,
        contentHash,
        metadata: jsonbParam({
          skills: sources.length,
          files: sources.reduce((sum, skill) => sum + skill.files.length, 0)
        }),
        syncedAt: sql`now()`
      })
      .onConflictDoUpdate({
        target: LibraryBuiltinSyncState.syncKey,
        set: {
          contentHash,
          metadata: jsonbParam({
            skills: sources.length,
            files: sources.reduce((sum, skill) => sum + skill.files.length, 0)
          }),
          syncedAt: sql`now()`
        }
      })
  })

  return {
    changed: true,
    contentHash,
    diagnostics,
    skills: sources.length,
    files: sources.reduce((sum, skill) => sum + skill.files.length, 0)
  }
}

export async function seedDefaultSoulForAgent(agentUid: string, executor: QueryExecutor = DB): Promise<void> {
  const content = await loadDefaultSoulTemplate()
  await upsertAgentTextEntry(executor, {
    agentUid,
    virtualPath: SOUL_FILE,
    sourceKind: 'soul',
    content,
    sourceRef: { source: 'app_template' }
  })
}

export async function seedDefaultMissionForAgent(agentUid: string, executor: QueryExecutor = DB): Promise<void> {
  const content = await loadDefaultMissionTemplate()
  await upsertAgentTextEntry(executor, {
    agentUid,
    virtualPath: MISSION_FILE,
    sourceKind: 'mission',
    content,
    sourceRef: { source: 'app_template' }
  })
}

export async function getSoul(agentUid: string, executor: QueryExecutor = DB): Promise<string | null> {
  const [row] = await executor
    .select({ contentText: AgentLibraryContainerEntries.contentText })
    .from(AgentLibraryContainerEntries)
    .where(activeAgentEntry(agentUid, SOUL_FILE))
    .limit(1)
  return row?.contentText ?? null
}

export async function setSoul(agentUid: string, content: string, executor: QueryExecutor = DB): Promise<void> {
  await upsertAgentTextEntry(executor, {
    agentUid,
    virtualPath: SOUL_FILE,
    sourceKind: 'soul',
    content,
    sourceRef: { source: 'api' }
  })
}

export async function getMission(agentUid: string, executor: QueryExecutor = DB): Promise<string | null> {
  const [row] = await executor
    .select({ contentText: AgentLibraryContainerEntries.contentText })
    .from(AgentLibraryContainerEntries)
    .where(activeAgentEntry(agentUid, MISSION_FILE))
    .limit(1)
  return row?.contentText ?? null
}

export async function setMission(agentUid: string, content: string, executor: QueryExecutor = DB): Promise<void> {
  await upsertAgentTextEntry(executor, {
    agentUid,
    virtualPath: MISSION_FILE,
    sourceKind: 'mission',
    content,
    sourceRef: { source: 'api' }
  })
}

export async function listEffectiveSkills(
  agentUid: string,
  executor: QueryExecutor = DB
): Promise<EffectiveSkillSummary[]> {
  const skills = await executor
    .select()
    .from(LibrarySkills)
    .where(and(eq(LibrarySkills.enabled, true), isNull(LibrarySkills.archivedAt)))
    .orderBy(asc(LibrarySkills.name))
  if (skills.length === 0) return []

  const assignments = await executor
    .select()
    .from(AgentSkillAssignments)
    .where(
      and(
        eq(AgentSkillAssignments.agentUid, agentUid),
        inArray(
          AgentSkillAssignments.skillId,
          skills.map(skill => skill.id)
        )
      )
    )
  const assignmentBySkill = new Map(assignments.map(row => [row.skillId, row]))
  const appendRows = await executor
    .select({ virtualPath: AgentLibraryContainerEntries.virtualPath })
    .from(AgentLibraryContainerEntries)
    .where(
      and(
        eq(AgentLibraryContainerEntries.agentUid, agentUid),
        eq(AgentLibraryContainerEntries.sourceKind, 'skill_append'),
        isNull(AgentLibraryContainerEntries.deletedAt),
        eq(AgentLibraryContainerEntries.enabled, true)
      )
    )
  const appendPaths = new Set(appendRows.map(row => row.virtualPath))

  return skills.flatMap(skill => {
    const assignment = assignmentBySkill.get(skill.id)
    const enabled = assignment?.enabled ?? skill.defaultEnabled
    if (!enabled) return []
    const metadata = skill.metadata ?? {}
    return [
      {
        id: skill.id,
        name: skill.name,
        description: skill.description,
        defaultEnabled: skill.defaultEnabled,
        enabled,
        sourceKind: skill.sourceKind,
        rootPath: skill.rootPath,
        tags: stringArray(metadata.tags),
        category: typeof metadata.category === 'string' ? metadata.category : undefined,
        metadata,
        hasAgentAppend: appendPaths.has(agentAppendPath(skill.name))
      }
    ]
  })
}

export async function searchEffectiveSkills(input: {
  agentUid: string
  query?: string
  limit?: number
  executor?: QueryExecutor
}): Promise<EffectiveSkillSummary[]> {
  const query = input.query?.trim().toLowerCase()
  const limit = Math.max(1, Math.min(input.limit ?? 20, 50))
  const skills = await listEffectiveSkills(input.agentUid, input.executor ?? DB)
  const matched = query
    ? skills.filter(skill => {
        const haystack = [
          skill.name,
          skill.description,
          skill.category ?? '',
          ...skill.tags,
          JSON.stringify(skill.metadata)
        ]
          .join('\n')
          .toLowerCase()
        const tokens = query.split(/[^a-z0-9_-]+/).filter(Boolean)
        return tokens.length === 0 ? true : tokens.every(token => haystack.includes(token))
      })
    : skills
  return matched.slice(0, limit)
}

export async function setAgentSkillEnabled(input: {
  agentUid: string
  skillName: string
  enabled: boolean
  reason?: string | null
  executor?: QueryExecutor
}): Promise<void> {
  const executor = input.executor ?? DB
  const skill = await getCanonicalSkillByName(input.skillName, executor)
  if (!skill) throw new Error(`unknown skill: ${input.skillName}`)
  await executor
    .insert(AgentSkillAssignments)
    .values({
      agentUid: input.agentUid,
      skillId: skill.id,
      enabled: input.enabled,
      reason: input.reason ?? null,
      metadata: jsonbParam({})
    })
    .onConflictDoUpdate({
      target: [AgentSkillAssignments.agentUid, AgentSkillAssignments.skillId],
      set: { enabled: input.enabled, reason: input.reason ?? null, updatedAt: sql`now()` }
    })
}

export async function setAgentSkillAppend(input: {
  agentUid: string
  skillName: string
  content: string
  executor?: QueryExecutor
}): Promise<void> {
  const executor = input.executor ?? DB
  const skill = await getCanonicalSkillByName(input.skillName, executor)
  if (!skill) throw new Error(`unknown skill: ${input.skillName}`)
  const diagnostics = auditSkillAppendContent(input.content)
  const errors = diagnostics.filter(diagnostic => diagnostic.severity === 'error')
  if (errors.length > 0) throw new SkillAppendRejectedError(errors)
  await upsertAgentTextEntry(executor, {
    agentUid: input.agentUid,
    virtualPath: agentAppendPath(skill.name),
    sourceKind: 'skill_append',
    content: input.content,
    sourceRef: { skill_id: skill.id, skill_name: skill.name }
  })
}

export async function getEffectiveSkillContent(input: {
  agentUid: string
  skillName: string
  filePath?: string
  executor?: QueryExecutor
}): Promise<EffectiveSkillContent | null> {
  const executor = input.executor ?? DB
  const summaries = await listEffectiveSkills(input.agentUid, executor)
  const summary = summaries.find(skill => skill.name === input.skillName)
  if (!summary) return null

  const filePath = normalizeSkillRelativePath(input.filePath ?? SKILL_FILE)
  if (filePath === AGENT_APPEND_FILE) {
    const append = await readAgentEntryText(input.agentUid, agentAppendPath(summary.name), executor)
    return append === null
      ? null
      : { ...summary, filePath: `/workspace/library-containers/${agentAppendPath(summary.name)}`, content: append }
  }

  const [file] = await executor
    .select()
    .from(LibrarySkillFiles)
    .where(and(eq(LibrarySkillFiles.skillId, summary.id), eq(LibrarySkillFiles.virtualPath, filePath)))
    .limit(1)
  if (!file) return null

  if (filePath !== SKILL_FILE) {
    return {
      ...summary,
      filePath: `/workspace/library-containers/skills/${summary.name}/${filePath}`,
      content: file.contentText
    }
  }

  const parsed = parseSkillFile(file.contentText)
  const baseContent = parsed.body.trim() ? parsed.body.trim() : file.contentText.trim()
  const appendContent = (await readAgentEntryText(input.agentUid, agentAppendPath(summary.name), executor))?.trim()
  const content = appendContent
    ? `${baseContent}\n\n---\nAgent-specific additions for ${input.agentUid}:\n\n${appendContent}`
    : baseContent
  return {
    ...summary,
    filePath: `/workspace/library-containers/skills/${summary.name}/${SKILL_FILE}`,
    content,
    baseContent,
    appendContent
  }
}

export async function listEffectiveLibraryContainerFiles(
  agentUid: string,
  executor: QueryExecutor = DB
): Promise<LibraryContainerFile[]> {
  const files: LibraryContainerFile[] = []

  const agentRows = await executor
    .select({
      virtualPath: AgentLibraryContainerEntries.virtualPath,
      content: AgentLibraryContainerEntries.contentText
    })
    .from(AgentLibraryContainerEntries)
    .where(
      and(
        eq(AgentLibraryContainerEntries.agentUid, agentUid),
        eq(AgentLibraryContainerEntries.enabled, true),
        isNull(AgentLibraryContainerEntries.deletedAt),
        sql`${AgentLibraryContainerEntries.contentText} is not null`,
        sql`(${AgentLibraryContainerEntries.virtualPath} = ${SOUL_FILE} or ${AgentLibraryContainerEntries.virtualPath} like 'skills/%/AGENT_APPEND.md')`
      )
    )
    .orderBy(asc(AgentLibraryContainerEntries.virtualPath))
  for (const row of agentRows) {
    if (row.content !== null) files.push({ virtualPath: row.virtualPath, content: row.content })
  }

  const summaries = await listEffectiveSkills(agentUid, executor)
  if (summaries.length === 0) return files

  const skillById = new Map(summaries.map(skill => [skill.id, skill]))
  const skillFiles = await executor
    .select()
    .from(LibrarySkillFiles)
    .where(
      inArray(
        LibrarySkillFiles.skillId,
        summaries.map(skill => skill.id)
      )
    )
    .orderBy(asc(LibrarySkillFiles.virtualPath))
  for (const file of skillFiles) {
    const skill = skillById.get(file.skillId)
    if (!skill) continue
    files.push({
      virtualPath: `skills/${skill.name}/${file.virtualPath}`,
      content: file.contentText
    })
  }

  return files
}

export async function skillsForSystemPrompt(agentUid: string, executor: QueryExecutor = DB): Promise<Skill[]> {
  const summaries = await listEffectiveSkills(agentUid, executor)
  return summaries.map(skill => ({
    name: skill.name,
    description: skill.description,
    category: skill.category,
    content: '',
    filePath: `/workspace/library-containers/skills/${skill.name}/${SKILL_FILE}`,
    disableModelInvocation: skill.metadata.disable_model_invocation === true
  }))
}

// Mirrors the worker-side upsert in packages/computer/src/tigerfs.rs: same
// conflict target and version bump. Schema changes must update both.
async function upsertAgentTextEntry(
  executor: QueryExecutor,
  input: {
    agentUid: string
    virtualPath: string
    sourceKind: 'soul' | 'mission' | 'skill_append' | 'setting' | 'memory' | 'system' | 'user' | 'computer'
    content: string
    sourceRef?: JsonObject
  }
): Promise<void> {
  const virtualPath = normalizeVirtualPath(input.virtualPath)
  const contentBlake3 = stableHash([input.content])
  await executor
    .insert(AgentLibraryContainerEntries)
    .values({
      id: genUUIDv7(),
      agentUid: input.agentUid,
      virtualPath,
      entryKind: 'file',
      sourceKind: input.sourceKind,
      sourceRef: jsonbParam(input.sourceRef ?? {}),
      contentText: input.content,
      contentBytes: null,
      contentMediaType: mediaTypeForPath(virtualPath),
      contentBlake3,
      metadata: jsonbParam({}),
      enabled: true,
      version: '1',
      deletedAt: null,
      updatedAt: sql`now()`
    })
    .onConflictDoUpdate({
      target: [AgentLibraryContainerEntries.agentUid, AgentLibraryContainerEntries.virtualPath],
      targetWhere: sql`${AgentLibraryContainerEntries.deletedAt} IS NULL`,
      set: {
        sourceKind: input.sourceKind,
        sourceRef: jsonbParam(input.sourceRef ?? {}),
        contentText: input.content,
        contentBytes: null,
        contentMediaType: mediaTypeForPath(virtualPath),
        contentBlake3,
        enabled: true,
        version: sql`(${AgentLibraryContainerEntries.version}::int + 1)::text`,
        deletedAt: null,
        updatedAt: sql`now()`
      }
    })
}

async function readAgentEntryText(
  agentUid: string,
  virtualPath: string,
  executor: QueryExecutor
): Promise<string | null> {
  const [row] = await executor
    .select({ contentText: AgentLibraryContainerEntries.contentText })
    .from(AgentLibraryContainerEntries)
    .where(activeAgentEntry(agentUid, virtualPath))
    .limit(1)
  return row?.contentText ?? null
}

function activeAgentEntry(agentUid: string, virtualPath: string) {
  return and(
    eq(AgentLibraryContainerEntries.agentUid, agentUid),
    eq(AgentLibraryContainerEntries.virtualPath, normalizeVirtualPath(virtualPath)),
    eq(AgentLibraryContainerEntries.enabled, true),
    isNull(AgentLibraryContainerEntries.deletedAt)
  )
}

async function getCanonicalSkillByName(name: string, executor: QueryExecutor) {
  const normalized = normalizeSkillName(name)
  const [skill] = await executor
    .select()
    .from(LibrarySkills)
    .where(and(eq(LibrarySkills.name, normalized), eq(LibrarySkills.enabled, true), isNull(LibrarySkills.archivedAt)))
    .limit(1)
  return skill
}

async function readBuiltinSkillSources(): Promise<{
  diagnostics: LibrarySkillDiagnostic[]
  sources: BuiltinSkillSource[]
}> {
  const byName = new Map<string, BuiltinSkillSource>()
  const diagnostics: LibrarySkillDiagnostic[] = []
  for (const sourceRoot of BUILTIN_SKILL_ROOTS) {
    const result = await readBuiltinSkillSourcesFromRoot(sourceRoot)
    diagnostics.push(...result.diagnostics)
    for (const source of result.sources) {
      byName.set(source.name, source)
    }
  }
  for (const diagnostic of diagnostics) logger.warn({ diagnostic }, 'Library skill sync diagnostic')
  return { diagnostics, sources: [...byName.values()].sort((a, b) => a.name.localeCompare(b.name)) }
}

async function readBuiltinSkillSourcesFromRoot(sourceRoot: {
  label: string
  root: string
}): Promise<{ diagnostics: LibrarySkillDiagnostic[]; sources: BuiltinSkillSource[] }> {
  let entries: Array<{ name: string; isDirectory(): boolean }>
  try {
    entries = (await readdir(sourceRoot.root, { withFileTypes: true })) as Array<{
      name: string
      isDirectory(): boolean
    }>
  } catch (error) {
    if (error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT') {
      return { diagnostics: [], sources: [] }
    }
    throw error
  }
  const sources: BuiltinSkillSource[] = []
  const diagnostics: LibrarySkillDiagnostic[] = []
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue
    const skillDir = path.join(sourceRoot.root, entry.name)
    const skillPath = path.join(skillDir, SKILL_FILE)
    const skillFile = Bun.file(skillPath)
    if (!(await skillFile.exists())) continue
    const ignoreRules = await readSkillSyncIgnoreRules(skillDir)
    const files = await readTextFilesRecursive(skillDir, '', ignoreRules)
    const skillMd = files.find(file => file.virtualPath === SKILL_FILE)
    if (!skillMd) continue
    const parsed = parseSkillFile(skillMd.content)
    const frontmatterName = typeof parsed.frontmatter.name === 'string' ? parsed.frontmatter.name.trim() : entry.name
    const skillDiagnostics = validateBuiltinSkillMetadata({
      description: parsed.frontmatter.description,
      directoryName: entry.name,
      name: frontmatterName,
      path: skillPath
    })
    diagnostics.push(...skillDiagnostics)
    if (skillDiagnostics.some(diagnostic => diagnostic.severity === 'error')) continue
    const name = normalizeSkillName(frontmatterName)
    const description = normalizeDescription(parsed.frontmatter.description)
    const defaultEnabled = parsed.frontmatter.default_enabled ?? parsed.frontmatter.defaultEnabled ?? true
    const metadata: JsonObject = {
      name,
      description,
      default_enabled: defaultEnabled,
      tags: stringArray(parsed.frontmatter.tags),
      disable_model_invocation: parsed.frontmatter['disable-model-invocation'] === true
    }
    if (typeof parsed.frontmatter.category === 'string') metadata.category = parsed.frontmatter.category
    sources.push({
      name,
      description,
      defaultEnabled,
      rootPath: `skills/${name}`,
      metadata,
      sourceHash: stableHash([sourceRoot.label, ...files.map(file => `${file.virtualPath}:${file.sha}`)]),
      sourceRoot: sourceRoot.label,
      files
    })
  }
  return { diagnostics, sources }
}

function validateBuiltinSkillMetadata(input: {
  description: unknown
  directoryName: string
  name: string
  path: string
}): LibrarySkillDiagnostic[] {
  const diagnostics: LibrarySkillDiagnostic[] = []
  try {
    const normalizedName = normalizeSkillName(input.name)
    if (input.name !== input.directoryName || normalizedName !== input.directoryName) {
      diagnostics.push({
        severity: 'error',
        code: 'name_directory_mismatch',
        message: `SKILL.md frontmatter name "${input.name}" must match directory "${input.directoryName}"`,
        path: input.path
      })
    }
  } catch (error) {
    diagnostics.push({
      severity: 'error',
      code: 'invalid_name',
      message: error instanceof Error ? error.message : String(error),
      path: input.path
    })
  }

  try {
    normalizeDescription(input.description)
  } catch (error) {
    diagnostics.push({
      severity: 'error',
      code: 'invalid_description',
      message: error instanceof Error ? error.message : String(error),
      path: input.path
    })
  }

  return diagnostics
}

interface SkillSyncIgnoreRule {
  pattern: string
  directoryOnly: boolean
  basenameOnly: boolean
}

async function readSkillSyncIgnoreRules(root: string): Promise<SkillSyncIgnoreRule[]> {
  const file = Bun.file(path.join(root, SKILL_SYNC_IGNORE_FILE))
  if (!(await file.exists())) return []
  const content = await file.text()
  return content
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(line => line && !line.startsWith('#'))
    .map(line => {
      const normalized = line.replace(/\\/g, '/').replace(/^\/+/, '')
      const directoryOnly = normalized.endsWith('/')
      const pattern = directoryOnly ? normalized.replace(/\/+$/, '') : normalized
      return {
        pattern,
        directoryOnly,
        basenameOnly: !pattern.includes('/')
      }
    })
    .filter(rule => rule.pattern.length > 0)
}

async function readTextFilesRecursive(
  root: string,
  relative = '',
  ignoreRules: SkillSyncIgnoreRule[] = []
): Promise<Array<{ virtualPath: string; content: string; sha: string }>> {
  const dir = path.join(root, relative)
  const entries = await readdir(dir, { withFileTypes: true })
  const files: Array<{ virtualPath: string; content: string; sha: string }> = []
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.name.startsWith('.')) continue
    const childRelative = relative ? `${relative}/${entry.name}` : entry.name
    const childPath = path.join(root, childRelative)
    if (isSkillSyncIgnored(childRelative, entry.isDirectory(), ignoreRules)) continue
    if (entry.isDirectory()) {
      files.push(...(await readTextFilesRecursive(root, childRelative, ignoreRules)))
      continue
    }
    if (!entry.isFile()) continue
    const content = await Bun.file(childPath).text()
    files.push({ virtualPath: normalizeSkillRelativePath(childRelative), content, sha: stableHash([content]) })
  }
  return files
}

function isSkillSyncIgnored(relativePath: string, isDirectory: boolean, rules: SkillSyncIgnoreRule[]): boolean {
  const normalized = normalizeSkillRelativePath(relativePath)
  const basename = normalized.split('/').pop() ?? normalized
  for (const rule of rules) {
    if (rule.directoryOnly && !isDirectory && !normalized.startsWith(`${rule.pattern}/`)) continue
    const target = rule.basenameOnly ? basename : normalized
    if (globLikeMatch(target, rule.pattern)) return true
    if (!rule.basenameOnly && (normalized === rule.pattern || normalized.startsWith(`${rule.pattern}/`))) return true
  }
  return false
}

function globLikeMatch(value: string, pattern: string): boolean {
  if (value === pattern) return true
  const escaped = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '[^/]*')
  return new RegExp(`^${escaped}$`).test(value)
}

function normalizeVirtualPath(value: string): string {
  const normalized = value.replace(/\\/g, '/').replace(/^\/+/, '').replace(/\/+/g, '/')
  if (!normalized || normalized.split('/').some(part => !part || part === '.' || part === '..')) {
    throw new Error(`invalid library virtual path: ${value}`)
  }
  return normalized
}

function normalizeSkillRelativePath(value: string): string {
  return normalizeVirtualPath(value)
}

function normalizeSkillName(value: string): string {
  const name = value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, '-')
  if (!/^[a-z][a-z0-9_-]{0,63}$/.test(name)) throw new Error(`invalid skill name: ${value}`)
  return name
}

function normalizeDescription(value: unknown): string {
  if (typeof value === 'string' && value.trim()) return value.trim().slice(0, 1024)
  throw new Error('SKILL.md frontmatter must include a non-empty description')
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.flatMap(item => (typeof item === 'string' ? [item] : [])) : []
}

function agentAppendPath(skillName: string): string {
  return `skills/${normalizeSkillName(skillName)}/${AGENT_APPEND_FILE}`
}

function stableHash(parts: string[]): string {
  return genericHash(parts.join('\0'))
}

function mediaTypeForPath(filePath: string): string {
  if (filePath.endsWith('.md')) return 'text/markdown'
  if (filePath.endsWith('.json')) return 'application/json'
  if (filePath.endsWith('.yaml') || filePath.endsWith('.yml')) return 'application/yaml'
  return 'text/plain'
}

export class SkillAppendRejectedError extends Error {
  constructor(readonly diagnostics: SkillContentDiagnostic[]) {
    super(`AGENT_APPEND.md rejected: ${diagnostics.map(diagnostic => diagnostic.message).join('; ')}`)
    this.name = 'SkillAppendRejectedError'
  }
}
