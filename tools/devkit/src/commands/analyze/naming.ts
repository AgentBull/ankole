import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import ts from 'typescript'
import { repoRootPath, runChildCaptured } from '../../utils'
import { canonicalCamelIdentifier, canonicalPascalIdentifier, canonicalSourcePath } from './naming-policy'
import type { CheckOptions, CheckResult, ExitCode } from './types'

export interface NamingViolation {
  actual: string
  expected: string
  file: string
  line: number
}

const scannedExtensions = new Set(['.ts', '.tsx', '.ex', '.exs', '.rs', '.proto'])

function canonicalIdentifier(value: string): string {
  if (value.includes('_') || value === value.toUpperCase() || value === value.toLowerCase()) return value
  return /^[a-z]/.test(value) ? canonicalCamelIdentifier(value) : canonicalPascalIdentifier(value)
}

function importedExternalName(node: ts.Identifier): boolean {
  const parent = node.parent
  return ts.isImportSpecifier(parent) && parent.propertyName === node && parent.name.text !== node.text
}

function ownedIdentifier(node: ts.Identifier): boolean {
  const parent = node.parent

  if (importedExternalName(node)) return false
  if (ts.isImportSpecifier(parent)) return parent.name === node
  if (ts.isImportClause(parent)) return parent.name === node
  if (ts.isNamespaceImport(parent)) return parent.name === node
  if (ts.isBindingElement(parent)) return parent.name === node
  if (ts.isVariableDeclaration(parent)) return parent.name === node
  if (ts.isParameter(parent)) return parent.name === node
  if (ts.isFunctionDeclaration(parent) || ts.isFunctionExpression(parent) || ts.isClassDeclaration(parent)) {
    return parent.name === node
  }
  if (ts.isClassExpression(parent) || ts.isInterfaceDeclaration(parent) || ts.isTypeAliasDeclaration(parent)) {
    return parent.name === node
  }
  if (ts.isEnumDeclaration(parent) || ts.isTypeParameterDeclaration(parent) || ts.isModuleDeclaration(parent)) {
    return parent.name === node
  }
  if (
    ts.isPropertyDeclaration(parent) ||
    ts.isPropertySignature(parent) ||
    ts.isPropertyAssignment(parent) ||
    ts.isShorthandPropertyAssignment(parent) ||
    ts.isMethodDeclaration(parent) ||
    ts.isMethodSignature(parent) ||
    ts.isGetAccessorDeclaration(parent) ||
    ts.isSetAccessorDeclaration(parent) ||
    ts.isEnumMember(parent)
  ) {
    return parent.name === node
  }
  if (ts.isExportSpecifier(parent)) return parent.name === node

  return false
}

export function findTypeScriptNamingViolations(file: string, source: string): NamingViolation[] {
  const sourceFile = ts.createSourceFile(
    file,
    source,
    ts.ScriptTarget.Latest,
    true,
    file.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS
  )
  const violations: NamingViolation[] = []

  function visit(node: ts.Node): void {
    if (ts.isIdentifier(node) && ownedIdentifier(node)) {
      const expected = canonicalIdentifier(node.text)
      if (expected !== node.text) {
        violations.push({
          actual: node.text,
          expected,
          file,
          line: sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1
        })
      }
    }
    ts.forEachChild(node, visit)
  }

  visit(sourceFile)
  return violations
}

function explicitlyAliased(line: string, actual: string, expected: string): boolean {
  const escapedActual = actual.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const rustAlias = new RegExp(`\\b${escapedActual}\\b\\s+as\\s+([A-Za-z][A-Za-z0-9]*)`, 'u').exec(line)?.[1]
  const elixirAlias = new RegExp(`\\b${escapedActual}\\b\\s*,\\s*as:\\s*([A-Za-z][A-Za-z0-9]*)`, 'u').exec(line)?.[1]
  const alias = rustAlias ?? elixirAlias
  return alias !== undefined && alias !== actual && canonicalIdentifier(alias) === alias && expected !== actual
}

export function findLexicalNamingViolations(file: string, source: string): NamingViolation[] {
  const violations: NamingViolation[] = []

  for (const [index, originalLine] of source.split('\n').entries()) {
    const line = originalLine
      .replace(/#.*$/u, '')
      .replace(/\/\/.*$/u, '')
      .replace(/"(?:\\.|[^"\\])*"/gu, '')
      .replace(/'(?:\\.|[^'\\])*'/gu, '')

    for (const match of line.matchAll(/\b[A-Za-z][A-Za-z0-9]*\b/gu)) {
      const actual = match[0]
      const expected = canonicalIdentifier(actual)
      if (expected !== actual && !explicitlyAliased(line, actual, expected)) {
        violations.push({ actual, expected, file, line: index + 1 })
      }
    }
  }

  return violations
}

function formatViolation(violation: NamingViolation): string {
  return `    - ${violation.file}:${violation.line} ${violation.actual} -> ${violation.expected}`
}

export async function runNaming(_options: CheckOptions = {}): Promise<CheckResult> {
  const listed = await runChildCaptured('git', ['ls-files', '-co', '--exclude-standard'], { cwd: repoRootPath })
  if (listed.status !== 0) {
    const message = listed.stderr.trim() || listed.error?.message || 'git ls-files failed'
    return {
      check: 'naming',
      ok: false,
      exitCode: 2,
      summary: 'ERROR (source listing failed)',
      human: `analyze:naming\n  ${message}`,
      json: { check: 'naming', ok: false, exitCode: 2, error: message }
    }
  }

  const files = listed.stdout
    .split('\n')
    .filter(Boolean)
    .filter(file => existsSync(path.join(repoRootPath, file)))
    .filter(file => scannedExtensions.has(path.extname(file)))
    .filter(file => !file.includes('/generated/') && !file.includes('/target/') && !file.includes('/deps/'))
  const violations: NamingViolation[] = []

  for (const file of files) {
    const expectedPath = canonicalSourcePath(file)
    if (expectedPath !== file) violations.push({ actual: file, expected: expectedPath, file, line: 1 })

    const source = readFileSync(path.join(repoRootPath, file), 'utf8')
    violations.push(
      ...(file.endsWith('.ts') || file.endsWith('.tsx')
        ? findTypeScriptNamingViolations(file, source)
        : findLexicalNamingViolations(file, source))
    )
  }

  const ok = violations.length === 0
  const exitCode: ExitCode = ok ? 0 : 1
  const human = ok
    ? 'analyze:naming\n  No naming convention violations.'
    : [
        'analyze:naming',
        `  ${violations.length} naming convention violations:`,
        ...violations.map(formatViolation)
      ].join('\n')

  return {
    check: 'naming',
    ok,
    exitCode,
    summary: ok ? 'PASS' : `FAIL (${violations.length} violations)`,
    human,
    json: { check: 'naming', ok, exitCode, violations }
  }
}
