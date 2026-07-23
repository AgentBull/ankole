import { existsSync, readFileSync, realpathSync, statSync } from 'node:fs'
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path'

type Mapping = Record<string, unknown>

const allowedRelations = new Set(['expected', 'compatible', 'tension', 'contradicts', 'unknown', 'not_applicable'])

const matrixPath = resolve(Bun.argv[2] ?? 'competing-hypotheses.yaml')

try {
  if (!existsSync(matrixPath)) throw new Error(`matrix does not exist: ${matrixPath}`)

  const matrix = Bun.YAML.parse(readFileSync(matrixPath, 'utf8'))
  const errors = validateMatrix(matrix, dirname(matrixPath))

  if (errors.length > 0) {
    process.stderr.write(`${errors.map(error => `- ${error}`).join('\n')}\n`)
    process.exitCode = 1
  } else {
    process.stdout.write('No ACH structure or local source-path issues found.\n')
  }
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
  process.exitCode = 1
}

function validateMatrix(value: unknown, workspaceRoot: string): string[] {
  const errors: string[] = []
  const matrix = mapping(value)
  if (!matrix) return ['matrix must be a mapping']

  const hypotheses = itemMappings(matrix.hypotheses, 'hypotheses', errors)
  const hypothesisIDs = collectIDs(hypotheses, 'hypothesis', errors)
  const hypothesisIDSet = new Set(hypothesisIDs)
  const rows = itemMappings(matrix.rows, 'rows', errors)
  collectIDs(rows, 'row', errors)

  for (const [index, row] of rows.entries()) {
    const label = `row ${rowLabel(row, index)}`
    validateProvenance(row, label, workspaceRoot, errors)
    validateRelations(row.relations, label, hypothesisIDs, hypothesisIDSet, errors)
  }

  validateJudgment(matrix.judgment, hypothesisIDSet, errors)
  return errors
}

function itemMappings(value: unknown, label: string, errors: string[]): Mapping[] {
  if (!Array.isArray(value)) {
    errors.push(`${label} must be a list`)
    return []
  }

  return value.flatMap((item, index) => {
    const result = mapping(item)
    if (result) return [result]
    errors.push(`${label}[${index}] must be a mapping`)
    return []
  })
}

function collectIDs(items: Mapping[], kind: string, errors: string[]): string[] {
  const ids: string[] = []
  const seen = new Set<string>()

  for (const [index, item] of items.entries()) {
    const id = nonEmptyString(item.id)
    if (!id) {
      errors.push(`${kind}[${index}] id must be a non-empty string`)
      continue
    }
    if (seen.has(id)) {
      errors.push(`duplicate ${kind} id: ${id}`)
      continue
    }
    seen.add(id)
    ids.push(id)
  }

  return ids
}

function validateProvenance(row: Mapping, label: string, workspaceRoot: string, errors: string[]): void {
  const analyticalBasis = nonEmptyString(row.analytical_basis)
  let hasSourcePath = false

  if (row.source_paths !== undefined) {
    if (!Array.isArray(row.source_paths)) {
      errors.push(`${label} source_paths must be a list`)
    } else {
      for (const [index, value] of row.source_paths.entries()) {
        const sourcePath = nonEmptyString(value)
        if (!sourcePath) {
          errors.push(`${label} source_paths[${index}] must be a non-empty string`)
          continue
        }
        hasSourcePath = true
        validateSourcePath(sourcePath, `${label} source_paths[${index}]`, workspaceRoot, errors)
      }
    }
  }

  if (!hasSourcePath && !analyticalBasis) {
    errors.push(`${label} requires a source path or analytical_basis`)
  }
}

function validateRelations(
  value: unknown,
  label: string,
  hypothesisIDs: string[],
  hypothesisIDSet: Set<string>,
  errors: string[]
): void {
  const relations = mapping(value)
  if (!relations) {
    errors.push(`${label} relations must be a mapping`)
    return
  }

  for (const hypothesisID of hypothesisIDs) {
    if (!Object.hasOwn(relations, hypothesisID)) errors.push(`${label} is missing relation for ${hypothesisID}`)
  }
  for (const hypothesisID of Object.keys(relations)) {
    if (!hypothesisIDSet.has(hypothesisID)) {
      errors.push(`${label} has relation for unknown hypothesis ${hypothesisID}`)
    }
  }

  for (const [hypothesisID, value] of Object.entries(relations)) {
    const relation = mapping(value)
    if (!relation) {
      errors.push(`${label} relation ${hypothesisID} must be a mapping`)
      continue
    }

    if (typeof relation.relation !== 'string' || !allowedRelations.has(relation.relation)) {
      errors.push(`${label} relation ${hypothesisID} has an invalid relation`)
    }
    if (!nonEmptyString(relation.rationale)) {
      errors.push(`${label} relation ${hypothesisID} requires a non-empty rationale`)
    }
  }
}

function validateJudgment(value: unknown, hypothesisIDs: Set<string>, errors: string[]): void {
  const judgment = mapping(value)
  if (!judgment) {
    errors.push('judgment must be a mapping')
    return
  }

  for (const key of Object.keys(judgment)) {
    if (key.includes('confidence') && !['confidence_basis', 'confidence_limits'].includes(key)) {
      errors.push(`judgment.${key} cannot store final confidence; put final confidence in report/report.md`)
    }
  }

  if (!nonEmptyString(judgment.confidence_basis)) {
    errors.push('judgment.confidence_basis must be a non-empty string')
  }
  if (!Array.isArray(judgment.confidence_limits)) {
    errors.push('judgment.confidence_limits must be a list')
  } else {
    for (const [index, value] of judgment.confidence_limits.entries()) {
      if (!nonEmptyString(value)) {
        errors.push(`judgment.confidence_limits[${index}] must be a non-empty string`)
      }
    }
  }

  if (!Array.isArray(judgment.hypothesis_refs)) {
    errors.push('judgment.hypothesis_refs must be a list')
    return
  }

  const seen = new Set<string>()
  for (const [index, value] of judgment.hypothesis_refs.entries()) {
    const hypothesisID = nonEmptyString(value)
    if (!hypothesisID) {
      errors.push(`judgment.hypothesis_refs[${index}] must be a non-empty string`)
      continue
    }
    if (seen.has(hypothesisID)) {
      errors.push(`duplicate judgment hypothesis reference: ${hypothesisID}`)
      continue
    }
    seen.add(hypothesisID)
    if (!hypothesisIDs.has(hypothesisID)) {
      errors.push(`judgment references unknown hypothesis ${hypothesisID}`)
    }
  }
}

function validateSourcePath(sourcePath: string, label: string, workspaceRoot: string, errors: string[]): void {
  if (sourcePath.includes('\0') || isAbsolute(sourcePath) || sourcePath.split(/[\\/]/).includes('..')) {
    errors.push(`${label} must be a safe project-relative path inside sources`)
    return
  }

  const sourceRoot = resolve(workspaceRoot, 'sources')
  const candidate = resolve(workspaceRoot, sourcePath)
  if (!inside(sourceRoot, candidate)) {
    errors.push(`${label} must stay inside sources`)
    return
  }
  if (!existsSync(candidate)) {
    errors.push(`${label} does not exist: ${sourcePath}`)
    return
  }

  const realWorkspaceRoot = realpathSync(workspaceRoot)
  const realSourceRoot = realpathSync(sourceRoot)
  const realCandidate = realpathSync(candidate)
  if (!inside(realWorkspaceRoot, realSourceRoot) || !inside(realSourceRoot, realCandidate)) {
    errors.push(`${label} escapes sources through a symbolic link`)
    return
  }
  if (!statSync(realCandidate).isFile()) {
    errors.push(`${label} must reference a file`)
  }
}

function inside(parent: string, child: string): boolean {
  const path = relative(parent, child)
  return path === '' || (!isAbsolute(path) && path !== '..' && !path.startsWith(`..${sep}`))
}

function rowLabel(row: Mapping, index: number): string {
  return nonEmptyString(row.id) ?? `[${index}]`
}

function mapping(value: unknown): Mapping | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? (value as Mapping) : undefined
}

function nonEmptyString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined
}
