import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'
import { API } from 'typescript/unstable/async'
import {
  isExportDeclaration,
  isFunctionDeclaration,
  isIdentifier,
  isImportDeclaration,
  isNamedExports,
  isNamedImports,
  isStringLiteral,
  isVariableStatement,
  NodeFlags,
  SyntaxKind,
  type Node,
  type SourceFile
} from 'typescript/unstable/ast'
import { createVirtualFileSystem } from 'typescript/unstable/fs'
import { repoRootPath } from '../../utils'
import { STRUCTURE_RULES, type StructureDirectoryRule, type StructureSourceRule } from './config'
import type { CheckOptions, CheckResult, ExitCode } from './types'

export interface StructureDiagnostic {
  conventionName: string
  filePath: string
  predicateName: 'declareConstants' | 'exportFunctions' | 'haveFiles' | 'haveType' | 'importValues'
  message: string
}

interface ParsedFileStructure {
  exportedFunctions: Set<string>
  declaredConstants: Set<string>
  importedValues: Array<{ name: string; from: string }>
}

const VIRTUAL_ROOT = '/virtual'
const VIRTUAL_TSCONFIG = `${VIRTUAL_ROOT}/tsconfig.json`

function infraResult(message: string): CheckResult {
  return {
    check: 'structure',
    ok: false,
    exitCode: 2,
    summary: 'ERROR (structure check failed to run)',
    human: `analyze:structure\n  structure check did not run cleanly:\n${message}`,
    json: { check: 'structure', ok: false, exitCode: 2, error: message }
  }
}

function formatDiagnostic(diagnostic: StructureDiagnostic): string {
  return `    - error ${diagnostic.filePath} [${diagnostic.conventionName}] ${diagnostic.predicateName}: ${diagnostic.message}`
}

function compareDiagnostics(left: StructureDiagnostic, right: StructureDiagnostic): number {
  return (
    left.filePath.localeCompare(right.filePath) ||
    left.conventionName.localeCompare(right.conventionName) ||
    left.predicateName.localeCompare(right.predicateName) ||
    left.message.localeCompare(right.message)
  )
}

function hasModifier(node: Node & { readonly modifiers?: readonly Node[] }, kind: SyntaxKind): boolean {
  return node.modifiers?.some(modifier => modifier.kind === kind) ?? false
}

function extractFileStructure(sourceFile: SourceFile): ParsedFileStructure {
  const localFunctions = new Set<string>()
  const exportedFunctions = new Set<string>()
  const pendingExportedAliases: Array<{ exportedName: string; localName: string }> = []
  const declaredConstants = new Set<string>()
  const importedValues: Array<{ name: string; from: string }> = []

  for (const statement of sourceFile.statements) {
    if (isFunctionDeclaration(statement) && statement.name) {
      localFunctions.add(statement.name.text)
      if (hasModifier(statement, SyntaxKind.ExportKeyword) && !hasModifier(statement, SyntaxKind.DefaultKeyword)) {
        exportedFunctions.add(statement.name.text)
      }
      continue
    }

    if (
      isExportDeclaration(statement) &&
      !statement.isTypeOnly &&
      !statement.moduleSpecifier &&
      statement.exportClause &&
      isNamedExports(statement.exportClause)
    ) {
      for (const element of statement.exportClause.elements) {
        if (element.isTypeOnly) continue
        pendingExportedAliases.push({
          exportedName: element.name.text,
          localName: (element.propertyName ?? element.name).text
        })
      }
      continue
    }

    if (isVariableStatement(statement) && (statement.declarationList.flags & NodeFlags.Const) !== 0) {
      for (const declaration of statement.declarationList.declarations) {
        if (isIdentifier(declaration.name)) {
          declaredConstants.add(declaration.name.text)
        }
      }
      continue
    }

    if (isImportDeclaration(statement) && isStringLiteral(statement.moduleSpecifier)) {
      const clause = statement.importClause
      if (!clause || clause.phaseModifier === SyntaxKind.TypeKeyword) continue
      if (clause.namedBindings && isNamedImports(clause.namedBindings)) {
        for (const element of clause.namedBindings.elements) {
          if (element.isTypeOnly) continue
          importedValues.push({
            name: (element.propertyName ?? element.name).text,
            from: statement.moduleSpecifier.text
          })
        }
      }
    }
  }

  for (const { exportedName, localName } of pendingExportedAliases) {
    if (localFunctions.has(localName)) {
      exportedFunctions.add(exportedName)
    }
  }

  return { exportedFunctions, declaredConstants, importedValues }
}

async function parseStructures(sources: Readonly<Record<string, string>>): Promise<Map<string, ParsedFileStructure>> {
  const entries = Object.entries(sources)
  if (entries.length === 0) return new Map()

  const virtualFiles: Record<string, string> = {}
  const virtualPaths: string[] = []
  for (const [repoPath, content] of entries) {
    const virtualPath = path.posix.join(VIRTUAL_ROOT, repoPath)
    virtualFiles[virtualPath] = content
    virtualPaths.push(virtualPath)
  }
  virtualFiles[VIRTUAL_TSCONFIG] = JSON.stringify({
    compilerOptions: {
      allowJs: true,
      jsx: 'preserve',
      module: 'esnext',
      noLib: true,
      noResolve: true,
      target: 'esnext',
      types: []
    },
    files: virtualPaths
  })

  const api = new API({
    cwd: VIRTUAL_ROOT,
    fs: createVirtualFileSystem(virtualFiles)
  })
  try {
    const snapshot = await api.updateSnapshot({ openProject: VIRTUAL_TSCONFIG })
    const project = snapshot.getProject(VIRTUAL_TSCONFIG)
    if (!project) {
      throw new Error('TypeScript 7 API did not open virtual structure project')
    }

    const parsed = new Map<string, ParsedFileStructure>()
    for (const [repoPath] of entries) {
      const virtualPath = path.posix.join(VIRTUAL_ROOT, repoPath)
      const sourceFile = await project.program.getSourceFile(virtualPath)
      if (!sourceFile) {
        throw new Error(`TypeScript 7 API did not parse ${repoPath}`)
      }
      parsed.set(repoPath, extractFileStructure(sourceFile))
    }
    return parsed
  } finally {
    await api.close()
  }
}

function collectSubpaths(baseDir: string, maxDepth: number, prefix = '', depth = 1): string[] {
  if (!existsSync(baseDir)) return []

  const results: string[] = []
  for (const entry of readdirSync(baseDir, { withFileTypes: true })) {
    if (entry.name.startsWith('.') || entry.name === 'node_modules') continue
    const subpath = prefix ? `${prefix}/${entry.name}` : entry.name
    if (entry.isFile()) {
      results.push(subpath)
    } else if (entry.isDirectory() && depth < maxDepth) {
      results.push(...collectSubpaths(path.join(baseDir, entry.name), maxDepth, subpath, depth + 1))
    }
  }
  return results
}

/** Evaluates source-level structural rules against an in-memory `{ [repoPath]: source }` map. */
export async function checkStructureSources(
  sources: Readonly<Record<string, string>>,
  rules: readonly StructureSourceRule[] = STRUCTURE_RULES.filter(
    (rule): rule is StructureSourceRule => rule.kind === 'source'
  )
): Promise<StructureDiagnostic[]> {
  const matched: Array<{
    repoPath: string
    rule: StructureSourceRule
    captures: Record<string, string | undefined>
  }> = []
  const filesToParse: Record<string, string> = {}

  for (const [repoPath, content] of Object.entries(sources)) {
    const normalized = repoPath.replaceAll('\\', '/')
    for (const rule of rules) {
      const prefix = `${rule.directory}/`
      if (!normalized.startsWith(prefix)) continue
      const subpath = normalized.slice(prefix.length)
      const match = rule.subpathPattern.exec(subpath)
      if (!match) continue
      matched.push({ repoPath: normalized, rule, captures: match.groups ?? {} })
      filesToParse[normalized] = content
    }
  }

  const parsedByFile = await parseStructures(filesToParse)
  const diagnostics: StructureDiagnostic[] = []

  for (const { repoPath, rule, captures } of matched) {
    const structure = parsedByFile.get(repoPath)
    if (!structure) continue

    for (const fnName of rule.exportFunctions?.(captures) ?? []) {
      if (!structure.exportedFunctions.has(fnName)) {
        diagnostics.push({
          conventionName: rule.name,
          filePath: repoPath,
          predicateName: 'exportFunctions',
          message: `Missing required exported function "${fnName}"`
        })
      }
    }

    for (const requiredImport of rule.importValues?.(captures) ?? []) {
      const found = structure.importedValues.some(
        item => item.name === requiredImport.name && item.from === requiredImport.from
      )
      if (!found) {
        diagnostics.push({
          conventionName: rule.name,
          filePath: repoPath,
          predicateName: 'importValues',
          message: `Missing required value import "${requiredImport.name}" from "${requiredImport.from}"`
        })
      }
    }

    for (const constName of rule.declareConstants?.(captures) ?? []) {
      if (!structure.declaredConstants.has(constName)) {
        diagnostics.push({
          conventionName: rule.name,
          filePath: repoPath,
          predicateName: 'declareConstants',
          message: `Missing required top-level constant "${constName}"`
        })
      }
    }
  }

  return diagnostics.toSorted(compareDiagnostics)
}

/** Evaluates filesystem directory/file conventions rooted at `rootPath`. */
export function checkDirectoryRules(
  rootPath: string,
  rules: readonly StructureDirectoryRule[] = STRUCTURE_RULES.filter(
    (rule): rule is StructureDirectoryRule => rule.kind === 'directory'
  )
): StructureDiagnostic[] {
  const diagnostics: StructureDiagnostic[] = []

  for (const rule of rules) {
    const parentAbs = path.join(rootPath, rule.parentDirectory)
    if (!existsSync(parentAbs)) continue

    for (const entryName of readdirSync(parentAbs)) {
      if (entryName.startsWith('.')) continue
      const entryRel = path.posix.join(rule.parentDirectory, entryName)
      const entryAbs = path.join(parentAbs, entryName)
      const stats = statSync(entryAbs)
      if (!stats.isDirectory()) {
        diagnostics.push({
          conventionName: rule.name,
          filePath: entryRel,
          predicateName: 'haveType',
          message: 'Expected a directory but found a file'
        })
        continue
      }

      for (const requiredRel of rule.requiredFiles(entryName)) {
        if (!existsSync(path.join(entryAbs, requiredRel))) {
          diagnostics.push({
            conventionName: rule.name,
            filePath: entryRel,
            predicateName: 'haveFiles',
            message: `Missing required file: ${requiredRel}`
          })
        }
      }
    }
  }

  return diagnostics.toSorted(compareDiagnostics)
}

export async function runStructure(_options: CheckOptions = {}): Promise<CheckResult> {
  try {
    const sourceRules = STRUCTURE_RULES.filter((rule): rule is StructureSourceRule => rule.kind === 'source')
    const directoryRules = STRUCTURE_RULES.filter((rule): rule is StructureDirectoryRule => rule.kind === 'directory')

    const sources: Record<string, string> = {}
    for (const rule of sourceRules) {
      const baseAbs = path.join(repoRootPath, rule.directory)
      for (const subpath of collectSubpaths(baseAbs, rule.maxDepth ?? 1)) {
        if (!rule.subpathPattern.test(subpath)) continue
        const repoPath = `${rule.directory}/${subpath}`
        sources[repoPath] ??= readFileSync(path.join(repoRootPath, repoPath), 'utf8')
      }
    }

    const diagnostics = [
      ...(await checkStructureSources(sources, sourceRules)),
      ...checkDirectoryRules(repoRootPath, directoryRules)
    ].toSorted(compareDiagnostics)

    const ok = diagnostics.length === 0
    const exitCode: ExitCode = ok ? 0 : 1
    const humanLines = ['analyze:structure']
    if (ok) {
      humanLines.push('  No structural convention violations.')
    } else {
      humanLines.push(`  ${diagnostics.length} structural convention error${diagnostics.length === 1 ? '' : 's'}:`)
      humanLines.push(...diagnostics.map(formatDiagnostic))
    }

    return {
      check: 'structure',
      ok,
      exitCode,
      summary: ok ? 'PASS (0 errors)' : `FAIL (${diagnostics.length} error${diagnostics.length === 1 ? '' : 's'})`,
      human: humanLines.join('\n'),
      json: { check: 'structure', ok, exitCode, diagnostics }
    }
  } catch (error) {
    return infraResult(error instanceof Error ? error.message : String(error))
  }
}
