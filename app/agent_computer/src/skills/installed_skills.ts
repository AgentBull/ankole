import type { Dirent } from 'node:fs'
import { lstat, readdir, readFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { YAML } from 'bun'
import type { AnkoleSkillRuntime } from './effective-skill'
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
  snapshot: string
}

type SkillFrontmatter = Record<string, unknown>

const skillFileName = 'SKILL.md'
const maxInstalledSkills = 200
const ankoleSkillRuntimes = new Set<AnkoleSkillRuntime>(['any', 'main', 'background_job'])

export async function scanInstalledSkills(root: string): Promise<InstalledSkillScanResult> {
  const diagnostics: InstalledSkillDiagnostic[] = []
  const agentDir = resolve(root)

  let entries: Dirent[]
  try {
    entries = await readdir(agentDir, { withFileTypes: true })
  } catch (error) {
    if (nodeErrorCode(error) === 'ENOENT') return emptyScan(diagnostics)
    throw error
  }

  const observations: InstalledSkillObservation[] = []
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    if (entry.name.startsWith('.')) continue

    const skillDir = join(agentDir, entry.name)
    if (entry.isSymbolicLink()) {
      diagnostics.push(diagnostic('symlink_skill_skipped', 'installed skill directory symlinks are ignored', skillDir))
      continue
    }
    if (!entry.isDirectory()) continue

    const observation = await readInstalledSkill(skillDir, entry.name, diagnostics)
    if (!observation) continue
    if (observations.length >= maxInstalledSkills) {
      throw new Error(`installed skill count exceeds ${maxInstalledSkills}`)
    }
    observations.push(observation)
  }

  return { observations, diagnostics, snapshot: installedSkillsSnapshot(observations) }
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

  const frontmatter = skillFrontmatter(rawSkill, skillPath, diagnostics)
  return frontmatter ? validateSkillMetadata(frontmatter, directoryName, skillPath, diagnostics) : null
}

function validateSkillMetadata(
  frontmatter: SkillFrontmatter,
  directoryName: string,
  skillPath: string,
  diagnostics: InstalledSkillDiagnostic[]
): InstalledSkillObservation | null {
  const rawName = stringScalar(frontmatter.name) ?? directoryName
  if (!isValidSkillName(rawName) || rawName !== directoryName) {
    diagnostics.push(
      diagnostic('skill_name_directory_mismatch', 'SKILL.md name must match the installed skill directory', skillPath)
    )
    return null
  }

  const description = stringScalar(frontmatter.description)
  if (!description) {
    diagnostics.push(diagnostic('skill_description_missing', 'SKILL.md description is required', skillPath))
    return null
  }

  const defaultEnabled = booleanScalar(frontmatter.default_enabled, true)
  if (defaultEnabled === null) {
    diagnostics.push(diagnostic('invalid_default_enabled', 'default_enabled must be true or false', skillPath))
    return null
  }

  const tags = stringList(frontmatter.tags)
  if (!tags) {
    diagnostics.push(diagnostic('invalid_skill_tags', 'tags must be a list of non-empty strings', skillPath))
    return null
  }

  const category = optionalStringScalar(frontmatter.category)
  if (category === null) {
    diagnostics.push(diagnostic('invalid_skill_category', 'category must be a non-empty string', skillPath))
    return null
  }

  const disableModelInvocation = booleanScalar(
    frontmatter['disable-model-invocation'] ?? frontmatter.disable_model_invocation,
    false
  )
  if (disableModelInvocation === null) {
    diagnostics.push(
      diagnostic('invalid_disable_model_invocation', 'disable-model-invocation must be true or false', skillPath)
    )
    return null
  }

  const ankoleRuntime = optionalStringScalar(frontmatter['ankole-runtime'])
  if (ankoleRuntime === null || (ankoleRuntime !== undefined && !isAnkoleSkillRuntime(ankoleRuntime))) {
    diagnostics.push(
      diagnostic('invalid_ankole_runtime', 'ankole-runtime must be any, main, or background_job', skillPath)
    )
    return null
  }

  return {
    skill_name: rawName,
    description: description.slice(0, 1024),
    default_enabled: defaultEnabled,
    tags,
    ...(category ? { category } : {}),
    disable_model_invocation: disableModelInvocation,
    ...(ankoleRuntime ? { ankole_runtime: ankoleRuntime } : {})
  }
}

function skillFrontmatter(
  rawSkill: string,
  skillPath: string,
  diagnostics: InstalledSkillDiagnostic[]
): SkillFrontmatter | null {
  if (!rawSkill.startsWith('---')) return {}

  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(rawSkill)
  if (!match) {
    diagnostics.push(diagnostic('invalid_skill_frontmatter', 'SKILL.md frontmatter is not closed', skillPath))
    return null
  }

  try {
    const value: unknown = YAML.parse(match[1] ?? '')
    if (value === null || value === undefined) return {}
    if (typeof value === 'object' && !Array.isArray(value)) return value as SkillFrontmatter
  } catch (error) {
    diagnostics.push(
      diagnostic(
        'invalid_skill_frontmatter',
        `SKILL.md frontmatter is invalid YAML: ${error instanceof Error ? error.message : String(error)}`,
        skillPath
      )
    )
    return null
  }

  diagnostics.push(diagnostic('invalid_skill_frontmatter', 'SKILL.md frontmatter must be a YAML object', skillPath))
  return null
}

function stringScalar(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined
}

function optionalStringScalar(value: unknown): string | undefined | null {
  if (value === undefined || value === null) return undefined
  return stringScalar(value) ?? null
}

function booleanScalar(value: unknown, fallback: boolean): boolean | null {
  if (value === undefined || value === null) return fallback
  return typeof value === 'boolean' ? value : null
}

function stringList(value: unknown): string[] | null {
  if (value === undefined || value === null) return []
  if (!Array.isArray(value)) return null

  const values = value.map(stringScalar)
  return values.every((item): item is string => typeof item === 'string') ? values : null
}

function installedSkillsSnapshot(observations: InstalledSkillObservation[]): string {
  return JSON.stringify(observations)
}

function emptyScan(diagnostics: InstalledSkillDiagnostic[]): InstalledSkillScanResult {
  return { observations: [], diagnostics, snapshot: installedSkillsSnapshot([]) }
}

function isAnkoleSkillRuntime(value: string): value is AnkoleSkillRuntime {
  return ankoleSkillRuntimes.has(value as AnkoleSkillRuntime)
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
