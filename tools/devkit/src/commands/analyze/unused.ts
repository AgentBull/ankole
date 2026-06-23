// `analyze unused` — Knip unused-file gate vs the owner/reason allowlist.
//
// Runner is rewritten for bun (knip-bun, local bin, no pnpm dlx); the
// parse/compare/format core mirrors openclaw's check-deadcode-unused-files.mjs,
// adapted to knip v6's `--files` compact output (`<path>: <path>` lines, no
// section header) and bullx's top-level dirs.

import { repoRootPath, resolveLocalBin, runChildCaptured } from '../../utils'
import { UNUSED_ALLOWLIST, UNUSED_KNIP_ARGS, UNUSED_REPO_PATH_PREFIX } from './config'
import type { CheckOptions, CheckResult, ExitCode } from './types'

function uniqueSorted(values: readonly string[]): string[] {
  return [...new Set(values)].toSorted((left, right) => left.localeCompare(right))
}

/** Parse repo-relative unused-file paths from knip's compact `--files` output. */
export function parseKnipUnusedFiles(output: string): string[] {
  const files: string[] = []
  for (const line of output.split(/\r?\n/)) {
    const separator = line.indexOf(': ')
    const candidate = (separator === -1 ? line : line.slice(0, separator)).trim()
    if (UNUSED_REPO_PATH_PREFIX.test(candidate)) {
      files.push(candidate.replace(/^\.\//, ''))
    }
  }
  return uniqueSorted(files)
}

function infraResult(message: string): CheckResult {
  return {
    check: 'unused',
    ok: false,
    exitCode: 2,
    summary: 'ERROR (knip failed to run)',
    human: `analyze:unused\n  knip did not run cleanly:\n${message}`,
    json: { check: 'unused', ok: false, exitCode: 2, error: message }
  }
}

export async function runUnused(_options: CheckOptions = {}): Promise<CheckResult> {
  const bin = resolveLocalBin('knip-bun') ?? resolveLocalBin('knip')
  if (!bin) {
    return infraResult('knip binary not found in node_modules/.bin (run `bun install`).')
  }

  const result = await runChildCaptured(bin, [...UNUSED_KNIP_ARGS], { cwd: repoRootPath })
  const output = `${result.stdout}${result.stderr}`
  const actual = parseKnipUnusedFiles(output)

  // knip exits 0 when clean; a nonzero exit with nothing parseable is a real
  // tool failure (config error, crash), not a set of unused files.
  if (result.status === null || (result.status !== 0 && actual.length === 0)) {
    return infraResult(result.error?.message ?? result.stderr.trim() ?? output.trim())
  }

  const allowEntries = UNUSED_ALLOWLIST.map(entry => entry.file.replace(/^\.\//, ''))
  const allowed = uniqueSorted(allowEntries)
  const allowedSet = new Set(allowed)
  const actualSet = new Set(actual)

  const unexpected = actual.filter(file => !allowedSet.has(file))
  const stale = allowed.filter(file => !actualSet.has(file)) // soft warning
  const duplicateAllowed = allowEntries.length - new Set(allowEntries).size
  const allowlistSorted = JSON.stringify(allowEntries) === JSON.stringify(allowed)

  const ok = unexpected.length === 0
  const exitCode: ExitCode = ok ? 0 : 1

  const humanLines = ['analyze:unused']
  if (ok) {
    humanLines.push(`  No unexpected unused files (${actual.length} reported, ${allowed.length} allowlisted).`)
  } else {
    humanLines.push(`  ${unexpected.length} unexpected unused file(s):`)
    humanLines.push(...unexpected.map(file => `    - ${file}`))
    humanLines.push(
      '  Fix the file, declare it as an entry in knip.config.ts, or add it to UNUSED_ALLOWLIST (with owner/reason) in analyze/config.ts.'
    )
  }
  if (stale.length > 0) {
    humanLines.push(
      `  warning: ${stale.length} stale allowlist entr${stale.length === 1 ? 'y' : 'ies'} (no longer unused):`
    )
    humanLines.push(...stale.map(file => `    - ${file}`))
  }
  if (!allowlistSorted) {
    // Sorting is a soft warning because it affects reviewability, not runtime
    // architecture safety.
    humanLines.push('  warning: UNUSED_ALLOWLIST is not sorted.')
  }
  if (duplicateAllowed > 0) {
    humanLines.push(
      `  warning: UNUSED_ALLOWLIST has ${duplicateAllowed} duplicate entr${duplicateAllowed === 1 ? 'y' : 'ies'}.`
    )
  }

  return {
    check: 'unused',
    ok,
    exitCode,
    summary: ok
      ? `PASS (${actual.length} reported, ${allowed.length} allowlisted)`
      : `FAIL (${unexpected.length} unexpected unused file(s))`,
    human: humanLines.join('\n'),
    json: { check: 'unused', ok, exitCode, actual, unexpected, stale, allowlistSorted, duplicateAllowed }
  }
}
