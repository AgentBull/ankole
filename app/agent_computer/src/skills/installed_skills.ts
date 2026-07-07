import type { Dirent } from 'node:fs'
import { lstat, readdir, readFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { xxh3File128Hex, xxh3String128Hex } from '@ankole/kernel'
import { match, ResultAsync } from '@pleisto/active-support'
import type { JsonObject } from '@pleisto/active-support'
import type { InstalledSkillObservation } from './types'

export type InstalledSkillDiagnostic = {
  code: string
  message: string
  path: string
  severity: 'warning' | 'error'
}

export type InstalledSkillScanResult = {
  observations: InstalledSkillObservation[]
  diagnostics: InstalledSkillDiagnostic[]
  fingerprint: string
}

type SkillFileFingerprint = {
  path: string
  xxh3_128: string
}

type SkillFrontmatter = JsonObject

const skillFileName = 'SKILL.md'
const maxInstalledSkills = 200
const maxFilesPerSkill = 512
const excludedEntries = new Set(['target', 'node_modules', '__pycache__'])
const yamlBlockItemRegex = /^\s*-\s+(.+)\s*$/
const yamlBlockEndRegex = /^\S/

export async function scanInstalledSkills(root: string, agentUid: string): Promise<InstalledSkillScanResult> {
  const diagnostics: InstalledSkillDiagnostic[] = []
  const agentDir = agentSkillRoot(root, agentUid, diagnostics)
  if (!agentDir) return emptyScan(diagnostics)

  const entriesResult = await readDirEntries(agentDir)
  if (entriesResult.isErr()) {
    if (nodeErrorCode(entriesResult.error) === 'ENOENT') return emptyScan(diagnostics)
    throw entriesResult.error
  }
  const entries = entriesResult.value

  const observations: InstalledSkillObservation[] = []
  let truncated = false

  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.name.startsWith('.')) continue

    const skillDir = join(agentDir, entry.name)
    if (entry.isSymbolicLink()) {
      diagnostics.push(diagnostic('symlink_skill_skipped', 'installed skill directory symlinks are ignored', skillDir))
      continue
    }

    if (!entry.isDirectory()) continue
    if (observations.length >= maxInstalledSkills) {
      truncated = true
      continue
    }

    const observation = await readInstalledSkill(skillDir, entry.name, diagnostics)
    if (observation) observations.push(observation)
  }

  if (truncated) {
    diagnostics.push(
      diagnostic(
        'installed_skill_limit_reached',
        `installed skill scan truncated at ${maxInstalledSkills} skills`,
        agentDir
      )
    )
  }

  return {
    observations,
    diagnostics,
    fingerprint: installedSkillsFingerprint(observations)
  }
}

async function readInstalledSkill(
  skillDir: string,
  directoryName: string,
  diagnostics: InstalledSkillDiagnostic[]
): Promise<InstalledSkillObservation | null> {
  if (!isValidSkillName(directoryName)) {
    diagnostics.push(diagnostic('invalid_skill_directory_name', 'installed skill directory name is invalid', skillDir))
    return null
  }

  const skillPath = join(skillDir, skillFileName)
  let rawSkill: string
  try {
    if ((await lstat(skillPath)).isSymbolicLink()) {
      diagnostics.push(
        diagnostic('symlink_skill_file_skipped', 'installed skill entrypoint symlinks are ignored', skillPath)
      )
      return null
    }
    rawSkill = await readFile(skillPath, 'utf8')
  } catch (error) {
    if (nodeErrorCode(error) === 'ENOENT') return null
    throw error
  }

  const frontmatter = skillFrontmatter(rawSkill)
  const metadata = validateSkillMetadata(frontmatter, directoryName, skillPath, diagnostics)
  if (!metadata) return null

  const files = await readSkillFileFingerprints(skillDir, diagnostics)
  if (files.length === 0) return null

  const xxh3_128 = xxh3String128Hex(files.map(file => `${file.path}\0${file.xxh3_128}`).join('\0'))

  return {
    skill_name: metadata.name,
    relative_path: directoryName,
    description: metadata.description,
    default_enabled: metadata.default_enabled,
    metadata: metadata.metadata,
    xxh3_128,
    file_count: files.length
  }
}

function validateSkillMetadata(
  frontmatter: SkillFrontmatter,
  directoryName: string,
  skillPath: string,
  diagnostics: InstalledSkillDiagnostic[]
): {
  name: string
  description: string
  default_enabled: boolean
  metadata: JsonObject
} | null {
  const rawName = stringScalar(frontmatter, 'name') ?? directoryName
  if (!isValidSkillName(rawName) || rawName !== directoryName) {
    diagnostics.push(
      diagnostic('skill_name_directory_mismatch', 'SKILL.md name must match the installed skill directory', skillPath)
    )
    return null
  }

  const description = stringScalar(frontmatter, 'description')
  if (!description) {
    diagnostics.push(diagnostic('skill_description_missing', 'SKILL.md description is required', skillPath))
    return null
  }
  const normalizedDescription = description.slice(0, 1024)

  const defaultEnabled = booleanScalar(frontmatter, 'default_enabled', true)
  if (defaultEnabled === null) {
    diagnostics.push(diagnostic('invalid_default_enabled', 'default_enabled must be true or false', skillPath))
    return null
  }

  const tags = tagsScalar(frontmatter)
  const category = stringScalar(frontmatter, 'category')
  const disableModelInvocation =
    optionalBooleanScalar(frontmatter, 'disable-model-invocation') ??
    optionalBooleanScalar(frontmatter, 'disable_model_invocation') ??
    false

  const metadata: JsonObject = {
    name: rawName,
    description: normalizedDescription,
    default_enabled: defaultEnabled,
    relative_path: directoryName,
    tags,
    disable_model_invocation: disableModelInvocation
  }
  if (category) metadata.category = category

  return {
    name: rawName,
    description: normalizedDescription,
    default_enabled: defaultEnabled,
    metadata
  }
}

async function readSkillFileFingerprints(
  skillDir: string,
  diagnostics: InstalledSkillDiagnostic[]
): Promise<SkillFileFingerprint[]> {
  const files: SkillFileFingerprint[] = []
  const state = { limitReported: false }
  await readSkillFileFingerprintsRecursive(skillDir, '', files, diagnostics, state)
  return files.sort((a, b) => a.path.localeCompare(b.path))
}

async function readSkillFileFingerprintsRecursive(
  skillDir: string,
  relativeDir: string,
  files: SkillFileFingerprint[],
  diagnostics: InstalledSkillDiagnostic[],
  state: { limitReported: boolean }
): Promise<void> {
  if (files.length >= maxFilesPerSkill) return

  const dir = join(skillDir, relativeDir)
  const entries = await readdir(dir, { withFileTypes: true })

  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    if (files.length >= maxFilesPerSkill) {
      if (!state.limitReported) {
        state.limitReported = true
        diagnostics.push(
          diagnostic(
            'installed_skill_file_limit_reached',
            `installed skill scan truncated at ${maxFilesPerSkill} files`,
            dir
          )
        )
      }
      return
    }

    if (entry.name.startsWith('.') || excludedEntries.has(entry.name)) continue

    const relativePath = normalizeVirtualPath(join(relativeDir, entry.name))
    const fullPath = join(skillDir, relativePath)

    if (entry.isSymbolicLink()) {
      diagnostics.push(diagnostic('symlink_skill_file_skipped', 'installed skill file symlinks are ignored', fullPath))
      continue
    }

    if (entry.isDirectory()) {
      await readSkillFileFingerprintsRecursive(skillDir, relativePath, files, diagnostics, state)
      continue
    }

    if (entry.isFile()) {
      files.push({ path: relativePath, xxh3_128: xxh3File128Hex(fullPath) })
    }
  }
}

function agentSkillRoot(root: string, agentUid: string, diagnostics: InstalledSkillDiagnostic[]): string | undefined {
  if (!agentUid || agentUid.includes('/') || agentUid.includes('\\') || agentUid === '.' || agentUid === '..') {
    diagnostics.push(diagnostic('invalid_agent_uid', 'agent uid is not a valid installed-skill path segment', root))
    return undefined
  }

  const resolvedRoot = resolve(root)
  const resolvedAgentRoot = resolve(resolvedRoot, agentUid)
  if (resolvedAgentRoot === resolvedRoot || !resolvedAgentRoot.startsWith(`${resolvedRoot}/`)) {
    diagnostics.push(diagnostic('invalid_agent_skill_root', 'agent installed skill root escapes configured root', root))
    return undefined
  }

  return resolvedAgentRoot
}

function skillFrontmatter(rawSkill: string): SkillFrontmatter {
  if (!rawSkill.startsWith('---')) return {}
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(rawSkill)
  if (!match) return {}
  return parseSimpleFrontmatter(match[1] ?? '')
}

function parseSimpleFrontmatter(frontmatter: string): SkillFrontmatter {
  const result: SkillFrontmatter = { __raw: frontmatter }
  for (const line of frontmatter.split(/\r?\n/)) {
    const match = /^([A-Za-z0-9_-]+):\s*(.*?)\s*$/.exec(line)
    if (!match || match[2] === '') continue
    result[match[1]!] = stripQuotes(match[2]!)
  }
  return result
}

function stringScalar(frontmatter: SkillFrontmatter, key: string): string | undefined {
  const value = frontmatter[key]
  return typeof value === 'string' && value.trim() ? value.trim() : undefined
}

function booleanScalar(frontmatter: SkillFrontmatter, key: string, fallback: boolean): boolean | null {
  return parseBooleanFrontmatter(frontmatter[key], fallback)
}

function optionalBooleanScalar(frontmatter: SkillFrontmatter, key: string): boolean | null | undefined {
  return parseBooleanFrontmatter(frontmatter[key], undefined)
}

function parseBooleanFrontmatter(value: unknown, fallback: boolean): boolean | null
function parseBooleanFrontmatter(value: unknown, fallback: undefined): boolean | null | undefined
function parseBooleanFrontmatter(value: unknown, fallback: boolean | undefined): boolean | null | undefined {
  return match(value)
    .with(undefined, () => fallback)
    .with(true, 'true', 'TRUE', () => true)
    .with(false, 'false', 'FALSE', () => false)
    .otherwise(() => null)
}

function tagsScalar(frontmatter: SkillFrontmatter): string[] {
  const inline = stringScalar(frontmatter, 'tags')
  if (inline?.startsWith('[')) {
    return inline
      .replace(/^\[/, '')
      .replace(/\]$/, '')
      .split(',')
      .map(value => stripQuotes(value.trim()))
      .filter(Boolean)
  }

  return collectYamlBlockList(frontmatterRawLines(frontmatter), 'tags')
}

function frontmatterRawLines(frontmatter: SkillFrontmatter): string[] {
  const raw = typeof frontmatter.__raw === 'string' ? frontmatter.__raw : ''
  return raw.split(/\r?\n/)
}

function collectYamlBlockList(lines: string[], key: string): string[] {
  const values: string[] = []
  let inside = false

  for (const line of lines) {
    if (!inside && new RegExp(`^${escapeRegex(key)}:\\s*$`).test(line)) {
      inside = true
      continue
    }

    if (!inside) continue

    const item = yamlBlockItemRegex.exec(line)
    if (item) {
      values.push(stripQuotes(item[1]!.trim()))
      continue
    }

    if (yamlBlockEndRegex.test(line)) break
  }

  return values
}

function installedSkillsFingerprint(observations: InstalledSkillObservation[]): string {
  return xxh3String128Hex(
    observations
      .map(observation => `${observation.skill_name}\0${observation.relative_path}\0${observation.xxh3_128}`)
      .join('\0')
  )
}

function readDirEntries(path: string): ResultAsync<Dirent[], unknown> {
  return ResultAsync.fromPromise(readdir(path, { withFileTypes: true }), error => error)
}

function emptyScan(diagnostics: InstalledSkillDiagnostic[]): InstalledSkillScanResult {
  return {
    observations: [],
    diagnostics,
    fingerprint: installedSkillsFingerprint([])
  }
}

function normalizeVirtualPath(value: string): string {
  return value.replaceAll('\\', '/').replace(/^\/+/, '').replace(/\/+/g, '/')
}

function isValidSkillName(name: string): boolean {
  return /^[a-z][a-z0-9_-]{0,63}$/.test(name)
}

function nodeErrorCode(error: unknown): string | undefined {
  return error && typeof error === 'object' && 'code' in error ? String(error.code) : undefined
}

function diagnostic(code: string, message: string, path: string): InstalledSkillDiagnostic {
  return { code, message, path, severity: 'warning' }
}

function stripQuotes(value: string): string {
  const trimmed = value.trim()
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    return trimmed.slice(1, -1)
  }
  return trimmed
}

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}
