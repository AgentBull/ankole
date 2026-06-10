// `analyze smells` — bullx boundary / architecture-smell gate.
//
// Rules are bullx-specific (the OpenClaw smells don't apply); only the regex
// reference scanner is ported. Four rules:
//   ① sdk must not re-export app/plugin internals
//   ② plugin/** must not import app internals
//   ③ app core must not reverse-import plugin implementation (discovery exempt)
//   ④ public-ish barrels may only re-export from an allowed module list

import { readFileSync } from 'node:fs'
import path from 'node:path'
import { repoRootPath } from '../../utils'
import {
  BARREL_ALLOWLIST,
  BARREL_EXPORT_CATEGORY,
  BOUNDARY_RULES,
  SMELL_SCAN_ROOTS,
  SMELL_SOURCE_EXTENSIONS
} from './config'
import { collectSourceFiles } from './lib/import-cycle-graph'
import { collectModuleReferencesFromSource, resolveRelativeSpecifier } from './lib/scan'
import type { CheckOptions, CheckResult, Finding } from './types'

const skipRepoPath = (repoPath: string): boolean =>
  /(^|\/)node_modules(\/|$)/.test(repoPath) ||
  /\.d\.[cm]?ts$/.test(repoPath) ||
  /(?:\.test|\.e2e\.test)\.[cm]?[tj]sx?$/.test(repoPath)

function compareFindings(left: Finding, right: Finding): number {
  return (
    left.category.localeCompare(right.category) ||
    left.file.localeCompare(right.file) ||
    left.line - right.line ||
    left.specifier.localeCompare(right.specifier)
  )
}

function scanFile(file: string): Finding[] {
  const source = readFileSync(path.join(repoRootPath, file), 'utf8')
  const references = collectModuleReferencesFromSource(source)
  const findings: Finding[] = []

  for (const rule of BOUNDARY_RULES) {
    if (!rule.appliesTo.test(file)) {
      continue
    }
    if (rule.exemptImporters?.some(pattern => pattern.test(file))) {
      continue
    }
    for (const reference of references) {
      const resolved = resolveRelativeSpecifier(file, reference.specifier)
      const resolvedHit = resolved && rule.forbidResolvedPrefixes.some(prefix => resolved.startsWith(prefix))
      const bareHit = rule.forbidBareSpecifiers.some(pattern => pattern.test(reference.specifier))
      if (resolvedHit || bareHit) {
        findings.push({
          category: rule.category,
          file,
          line: reference.line,
          kind: reference.kind,
          specifier: reference.specifier,
          resolved: resolved ?? reference.specifier,
          reason: rule.reason
        })
      }
    }
  }

  const barrel = BARREL_ALLOWLIST[file]
  if (barrel) {
    const allowed = new Set(barrel.allowed)
    for (const reference of references) {
      if (reference.kind !== 'export' || !reference.specifier.startsWith('.')) {
        continue
      }
      if (!allowed.has(reference.specifier)) {
        findings.push({
          category: BARREL_EXPORT_CATEGORY,
          file,
          line: reference.line,
          kind: reference.kind,
          specifier: reference.specifier,
          resolved: reference.specifier,
          reason: `barrel re-exports '${reference.specifier}' outside its allowed surface`
        })
      }
    }
  }

  return findings
}

function formatHuman(findings: readonly Finding[]): string {
  if (findings.length === 0) {
    return 'analyze:smells\n  No boundary violations found.'
  }
  const lines = ['analyze:smells']
  let activeCategory = ''
  let activeFile = ''
  for (const finding of findings) {
    if (finding.category !== activeCategory) {
      activeCategory = finding.category
      activeFile = ''
      lines.push(`[${finding.category}]`)
    }
    if (finding.file !== activeFile) {
      activeFile = finding.file
      lines.push(`  ${finding.file}`)
    }
    lines.push(`    - line ${finding.line} [${finding.kind}] ${finding.reason}`)
    lines.push(`      specifier: ${finding.specifier}  ->  ${finding.resolved}`)
  }
  return lines.join('\n')
}

export function runSmells(_options: CheckOptions = {}): CheckResult {
  const files = SMELL_SCAN_ROOTS.flatMap(root =>
    collectSourceFiles(path.join(repoRootPath, root), {
      repoRoot: repoRootPath,
      sourceExtensions: SMELL_SOURCE_EXTENSIONS,
      shouldSkipRepoPath: skipRepoPath
    })
  )
  const findings = files.flatMap(scanFile).toSorted(compareFindings)
  const ok = findings.length === 0

  return {
    check: 'smells',
    ok,
    exitCode: ok ? 0 : 1,
    summary: ok ? `PASS (${files.length} files)` : `FAIL (${findings.length} boundary violation(s))`,
    human: `${formatHuman(findings)}\n${findings.length} smell${findings.length === 1 ? '' : 's'} found.`,
    json: { check: 'smells', ok, exitCode: ok ? 0 : 1, findings }
  }
}
