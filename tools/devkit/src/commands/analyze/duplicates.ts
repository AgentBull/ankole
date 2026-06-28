// `analyze duplicates` — jscpd cross-module duplication gate.
//
// Ported (min-change) from openclaw's check-duplicates.mjs: the git-ls-files
// coverage assertion and multi-scan loop. Reworked for jscpd v5's Rust CLI
// (positional PATHs + --ignore-pattern, no --pattern; --gitignore default-on)
// and the JSON report (`duplicates[]`) as the source of truth for the gate.

import { existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { repoRootPath, resolveLocalBin, runChildCaptured } from '../../utils'
import {
  DUP_FORMATS,
  DUP_IGNORE_PATTERNS,
  DUP_INTENTIONALLY_UNSCANNED,
  DUP_SCANS,
  DUP_SOURCE_EXTENSIONS,
  DUP_THRESHOLDS
} from './config'
import type { CheckResult, ExitCode } from './types'

export interface DuplicateFinding {
  scan: string
  format: string
  firstFile: string
  firstLines: [number, number]
  secondFile: string
  secondLines: [number, number]
  lines: number
  tokens: number
}

export interface DuplicatesOptions {
  json?: boolean
  coverageOnly?: boolean
  minLines?: number
  minTokens?: number
}

interface JscpdFileRef {
  name: string
  start: number
  end: number
}
interface JscpdDuplicate {
  firstFile: JscpdFileRef
  secondFile: JscpdFileRef
  lines: number
  tokens: number
  format: string
}

function infraResult(message: string): CheckResult {
  return {
    check: 'duplicates',
    ok: false,
    exitCode: 2,
    summary: 'ERROR (jscpd failed to run)',
    human: `analyze:duplicates\n  jscpd did not run cleanly:\n${message}`,
    json: { check: 'duplicates', ok: false, exitCode: 2, error: message }
  }
}

function isCovered(file: string): boolean {
  if (DUP_SCANS.some(scan => scan.paths.some(p => file === p || file.startsWith(`${p}/`)))) {
    return true
  }
  return DUP_INTENTIONALLY_UNSCANNED.some(prefix => (prefix.endsWith('/') ? file.startsWith(prefix) : file === prefix))
}

/** Finds tracked source files that are neither scanned nor explicitly excluded. */
async function assertTargetCoverage(): Promise<string[]> {
  const result = await runChildCaptured('git', ['ls-files', '-z'], { cwd: repoRootPath })
  if (result.status !== 0) {
    throw new Error(result.stderr.trim() || 'git ls-files failed')
  }
  return result.stdout
    .split('\0')
    .filter(Boolean)
    .map(file => file.split(path.sep).join('/'))
    .filter(file => existsSync(path.join(repoRootPath, file)))
    .filter(file => DUP_SOURCE_EXTENSIONS.has(path.extname(file)))
    .filter(file => !isCovered(file))
    .toSorted((left, right) => left.localeCompare(right))
}

/** Runs one jscpd scan and converts the JSON report into stable findings. */
async function runScan(
  bin: string,
  scan: { name: string; paths: string[] },
  minLines: number,
  minTokens: number,
  reportDir: string
): Promise<DuplicateFinding[]> {
  rmSync(reportDir, { recursive: true, force: true })
  mkdirSync(reportDir, { recursive: true })
  const result = await runChildCaptured(
    bin,
    [
      ...scan.paths,
      '--format',
      DUP_FORMATS,
      '--min-lines',
      String(minLines),
      '--min-tokens',
      String(minTokens),
      '--ignore-pattern',
      DUP_IGNORE_PATTERNS.join(','),
      '--reporters',
      'json',
      '--output',
      reportDir,
      '--silent'
    ],
    { cwd: repoRootPath }
  )
  const reportPath = path.join(reportDir, 'jscpd-report.json')
  let report: { duplicates?: JscpdDuplicate[] }
  try {
    report = JSON.parse(readFileSync(reportPath, 'utf8'))
  } catch {
    throw new Error(
      `jscpd produced no report for scan '${scan.name}' (status ${result.status ?? 'null'}): ${result.stderr.trim() || result.stdout.trim()}`
    )
  }
  return (report.duplicates ?? []).map(dup => ({
    scan: scan.name,
    format: dup.format,
    firstFile: dup.firstFile.name,
    firstLines: [dup.firstFile.start, dup.firstFile.end],
    secondFile: dup.secondFile.name,
    secondLines: [dup.secondFile.start, dup.secondFile.end],
    lines: dup.lines,
    tokens: dup.tokens
  }))
}

export async function runDuplicates(options: DuplicatesOptions = {}): Promise<CheckResult> {
  const minLines = options.minLines ?? DUP_THRESHOLDS.minLines
  const minTokens = options.minTokens ?? DUP_THRESHOLDS.minTokens

  let uncovered: string[]
  try {
    uncovered = await assertTargetCoverage()
  } catch (error) {
    return infraResult(error instanceof Error ? error.message : String(error))
  }

  if (options.coverageOnly) {
    const ok = uncovered.length === 0
    const human = ok
      ? 'analyze:duplicates\n  target coverage ok'
      : `analyze:duplicates\n  ${uncovered.length} tracked source file(s) outside scan targets / intentional excludes:\n${uncovered.map(f => `    - ${f}`).join('\n')}`
    return {
      check: 'duplicates',
      ok,
      exitCode: ok ? 0 : 1,
      summary: ok ? 'PASS (coverage ok)' : `FAIL (${uncovered.length} uncovered file(s))`,
      human,
      json: { check: 'duplicates', mode: 'coverage', ok, exitCode: ok ? 0 : 1, uncovered }
    }
  }

  const bin = resolveLocalBin('jscpd')
  if (!bin) {
    return infraResult('jscpd binary not found in node_modules/.bin (run `bun install`).')
  }

  const reportDir = path.join(tmpdir(), `ankole-analyze-jscpd-${process.pid}`)
  const findings: DuplicateFinding[] = []
  try {
    for (const scan of DUP_SCANS) {
      findings.push(...(await runScan(bin, scan, minLines, minTokens, reportDir)))
    }
  } catch (error) {
    return infraResult(error instanceof Error ? error.message : String(error))
  } finally {
    rmSync(reportDir, { recursive: true, force: true })
  }

  const coverageOk = uncovered.length === 0
  const ok = findings.length === 0 && coverageOk
  const exitCode: ExitCode = ok ? 0 : 1

  const humanLines = ['analyze:duplicates']
  if (findings.length === 0) {
    humanLines.push(`  No duplicates >= ${minLines} lines / ${minTokens} tokens.`)
  } else {
    humanLines.push(`  ${findings.length} clone(s) >= ${minLines} lines / ${minTokens} tokens:`)
    for (const finding of findings) {
      humanLines.push(
        `    - [${finding.format}] ${finding.lines} lines / ${finding.tokens} tokens`,
        `        ${finding.firstFile}:${finding.firstLines[0]}-${finding.firstLines[1]}`,
        `        ${finding.secondFile}:${finding.secondLines[0]}-${finding.secondLines[1]}`
      )
    }
  }
  if (!coverageOk) {
    humanLines.push(`  warning: ${uncovered.length} tracked source file(s) outside scan targets (run --coverage-only).`)
  }

  return {
    check: 'duplicates',
    ok,
    exitCode,
    summary: ok
      ? 'PASS (0 clones)'
      : `FAIL (${findings.length} clone(s)${coverageOk ? '' : `, ${uncovered.length} uncovered`})`,
    human: humanLines.join('\n'),
    json: { check: 'duplicates', ok, exitCode, thresholds: { minLines, minTokens }, findings, uncovered }
  }
}
