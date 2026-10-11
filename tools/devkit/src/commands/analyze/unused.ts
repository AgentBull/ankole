// Knip production graph gate. Test-only callers do not retain production code.
import { repoRootPath, resolveLocalBin, runChildCaptured } from '../../utils'
import { UNUSED_ALLOWLIST, UNUSED_KNIP_ARGS } from './config'
import type { CheckOptions, CheckResult, ExitCode } from './types'

const kinds = ['files', 'exports', 'types', 'dependencies'] as const
type UnusedKind = (typeof kinds)[number]
export type UnusedIssue = { file: string; kind: UnusedKind; name: string }

export function parseKnipIssues(output: string): UnusedIssue[] {
  const report: unknown = JSON.parse(output)
  if (!report || typeof report !== 'object' || !('issues' in report) || !Array.isArray(report.issues)) {
    throw new Error('Expected the Knip JSON issues array')
  }
  const issues: UnusedIssue[] = []
  for (const item of report.issues) {
    if (!item || typeof item.file !== 'string') throw new Error('Expected a Knip issue file')
    for (const kind of kinds) {
      if (!Array.isArray(item[kind])) throw new Error(`Expected Knip ${kind} in ${item.file}`)
      for (const entry of item[kind]) {
        if (!entry || typeof entry.name !== 'string') throw new Error(`Expected a Knip ${kind} name`)
        issues.push({ file: item.file.replace(/^\.\//, ''), kind, name: entry.name })
      }
    }
  }
  return issues.sort((a, b) => issueKey(a).localeCompare(issueKey(b)))
}

function issueKey(issue: UnusedIssue): string {
  return `${issue.file}: ${issue.kind}: ${issue.name}`
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
  if (!bin) return infraResult('knip binary not found in node_modules/.bin (run `bun install`).')

  const result = await runChildCaptured(bin, [...UNUSED_KNIP_ARGS], { cwd: repoRootPath })
  if (result.status !== 0 && result.status !== 1) {
    return infraResult(result.error?.message ?? (result.stderr.trim() || result.stdout.trim()))
  }
  let actual: UnusedIssue[]
  try {
    actual = parseKnipIssues(result.stdout)
  } catch (error) {
    return infraResult(`${String(error)}\n${result.stderr.trim()}`)
  }
  if (result.status !== 0 && actual.length === 0) {
    return infraResult(result.stderr.trim() || 'Knip exited without issues')
  }

  const allowed = UNUSED_ALLOWLIST.map(entry => entry.file)
  const allowedSet = new Set(allowed)
  const unusedFiles = new Set(actual.filter(issue => issue.kind === 'files').map(issue => issue.file))
  const unexpected = actual.filter(issue => issue.kind !== 'files' || !allowedSet.has(issue.file))
  const stale = allowed.filter(file => !unusedFiles.has(file))
  const ok = unexpected.length === 0
  const exitCode: ExitCode = ok ? 0 : 1
  const human = [
    'analyze:unused',
    ok
      ? `  No unexpected unused code (${actual.length} reported, ${allowed.length} allowlisted files).`
      : `  ${unexpected.length} unexpected unused item(s):`,
    ...unexpected.map(issue => `    - ${issueKey(issue)}`),
    ...stale.map(file => `  warning: stale file allowlist entry: ${file}`)
  ].join('\n')
  return {
    check: 'unused',
    ok,
    exitCode,
    summary: ok ? `PASS (${allowed.length} allowlisted files)` : `FAIL (${unexpected.length} unused items)`,
    human,
    json: { check: 'unused', ok, exitCode, actual, unexpected, stale }
  }
}
