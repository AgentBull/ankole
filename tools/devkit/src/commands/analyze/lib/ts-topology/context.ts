// Topology program context. The symbol-analysis helpers are verbatim from
// openclaw; `createProgramContext` is rewritten for bullx so the Program spans
// the whole monorepo (app + sdk + plugin) using the app tsconfig's compiler
// options (which carry the `@/*` path aliases). This lets the checker resolve
// `@/...` consumers natively and see cross-package consumers of the SDK.

import { execFileSync } from 'node:child_process'
import { readdirSync, statSync } from 'node:fs'
import path from 'node:path'
import ts from 'typescript'
import type { CanonicalSymbol, ProgramContext, SymbolKind } from './types'

// Extra source roots merged into the Program beyond the app tsconfig's own
// includes, so SDK/plugin entrypoints and consumers are analyzable.
const EXTRA_PROGRAM_ROOTS = ['packages/sdk/src', 'plugin/lark-adapter/src']

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) {
    throw new Error(message)
  }
}

function normalizePath(filePath: string): string {
  return filePath.split(path.sep).join(path.posix.sep)
}

function collectTsSourceFiles(root: string): string[] {
  let stat: ReturnType<typeof statSync>
  try {
    stat = statSync(root)
  } catch {
    return []
  }
  if (stat.isFile()) {
    return /\.tsx?$/.test(root) && !root.endsWith('.d.ts') ? [root] : []
  }
  if (!stat.isDirectory()) {
    return []
  }
  return readdirSync(root, { withFileTypes: true }).flatMap(entry =>
    entry.name === 'node_modules' ? [] : collectTsSourceFiles(path.join(root, entry.name))
  )
}

export function createProgramContext(repoRoot: string, tsconfigName = 'app/tsconfig.json'): ProgramContext {
  const configPath = path.join(repoRoot, tsconfigName)
  const host: ts.ParseConfigFileHost = {
    ...ts.sys,
    onUnRecoverableConfigFileDiagnostic(diagnostic) {
      throw new Error(ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n'))
    }
  }
  const parsed = ts.getParsedCommandLineOfConfigFile(configPath, undefined, host)
  assert(parsed, `Could not parse ${tsconfigName}`)

  const extra = EXTRA_PROGRAM_ROOTS.flatMap(root => collectTsSourceFiles(path.join(repoRoot, root)))
  const rootNames = [...new Set([...parsed.fileNames, ...extra])]
  const program = ts.createProgram(rootNames, parsed.options)

  return {
    repoRoot,
    tsconfigPath: normalizePath(path.relative(repoRoot, configPath)),
    program,
    checker: program.getTypeChecker(),
    normalizePath,
    relativeToRepo(filePath: string) {
      return normalizePath(path.relative(repoRoot, filePath))
    }
  }
}

export function comparableSymbol(checker: ts.TypeChecker, symbol: ts.Symbol | undefined): ts.Symbol | undefined {
  if (!symbol) {
    return undefined
  }
  return symbol.flags & ts.SymbolFlags.Alias ? checker.getAliasedSymbol(symbol) : symbol
}

function symbolKind(symbol: ts.Symbol, declaration: ts.Declaration | undefined): SymbolKind {
  if (declaration) {
    switch (declaration.kind) {
      case ts.SyntaxKind.FunctionDeclaration:
        return 'function'
      case ts.SyntaxKind.ClassDeclaration:
        return 'class'
      case ts.SyntaxKind.InterfaceDeclaration:
        return 'interface'
      case ts.SyntaxKind.TypeAliasDeclaration:
        return 'type'
      case ts.SyntaxKind.EnumDeclaration:
        return 'enum'
      case ts.SyntaxKind.VariableDeclaration:
        return 'variable'
      default:
        break
    }
  }
  if (symbol.flags & ts.SymbolFlags.Function) {
    return 'function'
  }
  if (symbol.flags & ts.SymbolFlags.Class) {
    return 'class'
  }
  if (symbol.flags & ts.SymbolFlags.Interface) {
    return 'interface'
  }
  if (symbol.flags & ts.SymbolFlags.TypeAlias) {
    return 'type'
  }
  if (symbol.flags & ts.SymbolFlags.Enum) {
    return 'enum'
  }
  if (symbol.flags & ts.SymbolFlags.Variable) {
    return 'variable'
  }
  return 'unknown'
}

export function canonicalSymbolInfo(context: ProgramContext, symbol: ts.Symbol): CanonicalSymbol {
  const resolved = comparableSymbol(context.checker, symbol) ?? symbol
  const declaration =
    resolved.getDeclarations()?.find(candidate => candidate.kind !== ts.SyntaxKind.SourceFile) ??
    symbol.getDeclarations()?.find(candidate => candidate.kind !== ts.SyntaxKind.SourceFile)
  assert(declaration, `Missing declaration for symbol ${symbol.getName()}`)
  const sourceFile = declaration.getSourceFile()
  const declarationPath = context.relativeToRepo(sourceFile.fileName)
  const declarationLine = sourceFile.getLineAndCharacterOfPosition(declaration.getStart()).line + 1
  return {
    canonicalKey: `${declarationPath}:${declarationLine}:${resolved.getName()}`,
    declarationPath,
    declarationLine,
    kind: symbolKind(resolved, declaration),
    aliasName: symbol.getName() !== resolved.getName() ? symbol.getName() : undefined
  }
}

export function countIdentifierUsages(
  context: ProgramContext,
  sourceFile: ts.SourceFile,
  importedSymbol: ts.Symbol,
  localName: string
): number {
  const targetSymbol = comparableSymbol(context.checker, importedSymbol)
  let count = 0
  const visit = (node: ts.Node) => {
    if (ts.isIdentifier(node) && node.text === localName) {
      const symbol = comparableSymbol(context.checker, context.checker.getSymbolAtLocation(node))
      if (symbol === targetSymbol && !ts.isImportClause(node.parent) && !ts.isImportSpecifier(node.parent)) {
        count += 1
      }
    }
    ts.forEachChild(node, visit)
  }
  ts.forEachChild(sourceFile, visit)
  return count
}

export function countNamespacePropertyUsages(
  context: ProgramContext,
  sourceFile: ts.SourceFile,
  namespaceSymbol: ts.Symbol,
  exportedName: string
): number {
  const targetSymbol = comparableSymbol(context.checker, namespaceSymbol)
  let count = 0
  const visit = (node: ts.Node) => {
    if (ts.isPropertyAccessExpression(node) && ts.isIdentifier(node.expression) && node.name.text === exportedName) {
      const symbol = comparableSymbol(context.checker, context.checker.getSymbolAtLocation(node.expression))
      if (symbol === targetSymbol) {
        count += 1
      }
    }
    ts.forEachChild(node, visit)
  }
  ts.forEachChild(sourceFile, visit)
  return count
}

export function getRepoRevision(repoRoot: string): string | null {
  try {
    return execFileSync('git', ['rev-parse', 'HEAD'], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    }).trim()
  } catch {
    return null
  }
}
