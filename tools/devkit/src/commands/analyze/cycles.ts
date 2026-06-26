// `analyze cycles` — runtime-value import-cycle gate (target = 0).
//
// Glue rewritten for Ankole around the verbatim Tarjan lib
// (./lib/import-cycle-graph). The resolver is alias-aware so package-local
// `@/*` imports participate in the graph instead of being treated as opaque
// bare package edges.

import { readFileSync } from 'node:fs'
import path from 'node:path'
import ts from 'typescript'
import { repoRootPath } from '../../utils'
import { ALIAS_TSCONFIGS, CYCLE_SCAN_ROOTS, CYCLE_SOURCE_EXTENSIONS } from './config'
import { collectSourceFiles, collectStronglyConnectedComponents, formatCycle } from './lib/import-cycle-graph'
import type { CheckOptions, CheckResult } from './types'

const testSourcePattern = /(?:\.test|\.e2e\.test)\.[cm]?[tj]sx?$/
const generatedSourcePattern = /\.(?:generated|bundle)\.[tj]s$/
const declarationSourcePattern = /\.d\.[cm]?ts$/
const ignoredPathPartPattern = /(^|\/)(node_modules|dist|build|coverage|\.artifacts|\.turbo|\.git|assets)(\/|$)/

interface AliasEntry {
  /** Package this alias applies to (importer must live under it). */
  packageRoot: string
  /** Specifier prefix, e.g. '@/' or '@locales/'. */
  aliasPrefix: string
  /** Repo-relative target roots, e.g. ['app/agent_computer/src/']. */
  targetRoots: string[]
}

/** Read `compilerOptions.paths` from each aliased package's tsconfig. */
function loadAliasTable(): AliasEntry[] {
  const entries: AliasEntry[] = []
  for (const { packageRoot, tsconfig } of ALIAS_TSCONFIGS) {
    const configPath = path.join(repoRootPath, tsconfig)
    const read = ts.readConfigFile(configPath, ts.sys.readFile)
    const paths = read.config?.compilerOptions?.paths as Record<string, string[]> | undefined
    if (!paths) {
      continue
    }
    for (const [alias, targets] of Object.entries(paths)) {
      const aliasPrefix = alias.replace(/\*$/, '')
      const targetRoots = targets.map(target => {
        const stripped = target.replace(/\*$/, '')
        return `${path.posix.join(packageRoot, stripped)}/`.replace(/\/+$/, '/')
      })
      entries.push({ packageRoot, aliasPrefix, targetRoots })
    }
  }
  return entries
}

type SourceResolver = (importerRepoPath: string, specifier: string) => string | null

/** Builds a resolver for relative imports and package-local TS path aliases. */
function createSourceResolver(files: readonly string[], aliasTable: readonly AliasEntry[]): SourceResolver {
  const fileSet = new Set(files)
  const pathMap = new Map<string, string>()
  for (const file of files) {
    const parsed = path.posix.parse(file)
    const extensionless = path.posix.join(parsed.dir, parsed.name)
    pathMap.set(extensionless, file)
    if (file.endsWith('.ts')) {
      pathMap.set(`${extensionless}.js`, file)
    } else if (file.endsWith('.tsx')) {
      pathMap.set(`${extensionless}.jsx`, file)
    } else if (file.endsWith('.mts')) {
      pathMap.set(`${extensionless}.mjs`, file)
    } else if (file.endsWith('.cts')) {
      pathMap.set(`${extensionless}.cjs`, file)
    }
  }

  const probe = (base: string): string | null => {
    const candidates = [
      base,
      ...CYCLE_SOURCE_EXTENSIONS.map(extension => `${base}${extension}`),
      `${base}/index.ts`,
      `${base}/index.tsx`,
      `${base}/index.js`,
      `${base}/index.mjs`
    ]
    for (const candidate of candidates) {
      if (fileSet.has(candidate)) {
        return candidate
      }
      const mapped = pathMap.get(candidate)
      if (mapped) {
        return mapped
      }
    }
    return null
  }

  return (importerRepoPath, specifier) => {
    if (specifier.startsWith('.')) {
      const base = path.posix.normalize(path.posix.join(path.posix.dirname(importerRepoPath), specifier))
      return probe(base)
    }
    // Alias: scope to the importer's owning package (so app's `@/` and sdk's
    // `@/` never cross). Longest packageRoot prefix wins.
    const owning = aliasTable
      .filter(entry => importerRepoPath.startsWith(`${entry.packageRoot}/`))
      .toSorted((a, b) => b.packageRoot.length - a.packageRoot.length)[0]?.packageRoot
    if (!owning) {
      return null
    }
    for (const entry of aliasTable) {
      if (entry.packageRoot !== owning || !specifier.startsWith(entry.aliasPrefix)) {
        continue
      }
      const rest = specifier.slice(entry.aliasPrefix.length)
      for (const targetRoot of entry.targetRoots) {
        const hit = probe(path.posix.normalize(`${targetRoot}${rest}`))
        if (hit) {
          return hit
        }
      }
    }
    // Bare workspace/npm/node specifier — a legitimate package boundary, not an
    // intra-repo edge. Excluded from the cycle graph (same as upstream).
    return null
  }
}

function importDeclarationHasRuntimeEdge(node: ts.ImportDeclaration): boolean {
  if (!node.importClause) {
    return true
  }
  if (node.importClause.isTypeOnly) {
    return false
  }
  const bindings = node.importClause.namedBindings
  if (node.importClause.name || !bindings || ts.isNamespaceImport(bindings)) {
    return true
  }
  return bindings.elements.some(element => !element.isTypeOnly)
}

/** Returns whether an export declaration creates a runtime dependency edge. */
function exportDeclarationHasRuntimeEdge(node: ts.ExportDeclaration): boolean {
  if (!node.moduleSpecifier || node.isTypeOnly) {
    return false
  }
  const clause = node.exportClause
  if (!clause || ts.isNamespaceExport(clause)) {
    return true
  }
  return clause.elements.some(element => !element.isTypeOnly)
}

/** Collects only static runtime imports so type-only edges do not fail the gate. */
function collectRuntimeStaticImports(file: string, resolveSource: SourceResolver): string[] {
  const sourceFile = ts.createSourceFile(
    file,
    readFileSync(path.join(repoRootPath, file), 'utf8'),
    ts.ScriptTarget.Latest,
    true
  )
  const imports: string[] = []
  const visit = (node: ts.Node) => {
    let specifier: string | undefined
    let include = false
    if (ts.isImportDeclaration(node) && ts.isStringLiteral(node.moduleSpecifier)) {
      specifier = node.moduleSpecifier.text
      include = importDeclarationHasRuntimeEdge(node)
    } else if (ts.isExportDeclaration(node) && node.moduleSpecifier && ts.isStringLiteral(node.moduleSpecifier)) {
      specifier = node.moduleSpecifier.text
      include = exportDeclarationHasRuntimeEdge(node)
    }
    if (include && specifier) {
      const resolved = resolveSource(file, specifier)
      if (resolved) {
        imports.push(resolved)
      }
    }
    ts.forEachChild(node, visit)
  }
  visit(sourceFile)
  return imports.toSorted((left, right) => left.localeCompare(right))
}

export interface CyclesOptions extends CheckOptions {
  includeTests?: boolean
}

/** Runs the runtime-value import-cycle gate over configured source roots. */
export function runCycles(options: CyclesOptions = {}): CheckResult {
  const shouldSkipRepoPath = (repoPath: string): boolean =>
    ignoredPathPartPattern.test(repoPath) ||
    generatedSourcePattern.test(repoPath) ||
    declarationSourcePattern.test(repoPath) ||
    (!options.includeTests && testSourcePattern.test(repoPath))

  const files = CYCLE_SCAN_ROOTS.flatMap(root =>
    collectSourceFiles(path.join(repoRootPath, root), {
      repoRoot: repoRootPath,
      sourceExtensions: CYCLE_SOURCE_EXTENSIONS,
      shouldSkipRepoPath
    })
  )
  const aliasTable = loadAliasTable()
  const resolveSource = createSourceResolver(files, aliasTable)
  const graph = new Map<string, string[]>(files.map(file => [file, collectRuntimeStaticImports(file, resolveSource)]))
  const edgeCount = [...graph.values()].reduce((total, edges) => total + edges.length, 0)
  const components = collectStronglyConnectedComponents(graph)
  const ok = components.length === 0

  const headline = `Import cycle check: ${components.length} runtime value cycle(s) over ${files.length} files, ${edgeCount} runtime edges.`
  const humanLines = [headline]
  if (!ok) {
    humanLines.push('', 'Runtime value import cycles:')
    for (const component of components) {
      humanLines.push(`\n# component size ${component.length}`)
      humanLines.push(formatCycle(component, graph))
    }
    humanLines.push('', 'Break the cycle or convert type-only edges to `import type`.')
  }

  return {
    check: 'cycles',
    ok,
    exitCode: ok ? 0 : 1,
    summary: ok
      ? `PASS (0 runtime value cycles, ${edgeCount} edges)`
      : `FAIL (${components.length} runtime value cycle(s))`,
    human: humanLines.join('\n'),
    json: {
      check: 'cycles',
      ok,
      exitCode: ok ? 0 : 1,
      fileCount: files.length,
      edgeCount,
      cycleCount: components.length,
      cycles: components.map(component => ({ size: component.length, files: component })),
      graph: options.json ? Object.fromEntries(graph) : undefined
    }
  }
}
