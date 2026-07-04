// `analyze structure` — konsistent structural convention gate.

import { repoRootPath, resolveLocalBin, runChildCaptured } from '../../utils'
import { STRUCTURE_KONSISTENT_CHECK_ARGS, STRUCTURE_KONSISTENT_VALIDATE_ARGS } from './config'
import type { CheckOptions, CheckResult, ExitCode } from './types'

interface KonsistentDiagnostic {
  conventionName?: string
  filePath?: string
  line?: number
  message?: string
  predicateName?: string
  severity?: 'error' | 'warning'
}

function infraResult(message: string): CheckResult {
  return {
    check: 'structure',
    ok: false,
    exitCode: 2,
    summary: 'ERROR (konsistent failed to run)',
    human: `analyze:structure\n  konsistent did not run cleanly:\n${message}`,
    json: { check: 'structure', ok: false, exitCode: 2, error: message }
  }
}

function parseDiagnostics(output: string): KonsistentDiagnostic[] | null {
  const trimmed = output.trim()
  if (trimmed.length === 0) return []

  try {
    const parsed = JSON.parse(trimmed)
    return Array.isArray(parsed) ? (parsed as KonsistentDiagnostic[]) : null
  } catch {
    return null
  }
}

function formatDiagnostic(diagnostic: KonsistentDiagnostic): string {
  const severity = diagnostic.severity ?? 'error'
  const file = diagnostic.filePath ?? '(unknown file)'
  const line = diagnostic.line === undefined ? '' : `:${diagnostic.line}`
  const convention = diagnostic.conventionName ? ` [${diagnostic.conventionName}]` : ''
  const predicate = diagnostic.predicateName ? ` ${diagnostic.predicateName}:` : ''
  const message = diagnostic.message ?? 'Structural convention violation'
  return `    - ${severity} ${file}${line}${convention}${predicate} ${message}`
}

export async function runStructure(_options: CheckOptions = {}): Promise<CheckResult> {
  const bin = resolveLocalBin('konsistent')
  if (!bin) {
    return infraResult('konsistent binary not found in node_modules/.bin (run `bun install`).')
  }

  const env = { ...process.env, KONSISTENT_NO_UPDATE_CHECK: 'true' }
  const validate = await runChildCaptured(bin, [...STRUCTURE_KONSISTENT_VALIDATE_ARGS], {
    cwd: repoRootPath,
    env
  })
  if (validate.status !== 0) {
    return infraResult(
      validate.stderr.trim() || validate.stdout.trim() || validate.error?.message || 'config validation failed'
    )
  }

  const result = await runChildCaptured(bin, [...STRUCTURE_KONSISTENT_CHECK_ARGS], {
    cwd: repoRootPath,
    env
  })
  if (result.status === null) {
    return infraResult(result.error?.message ?? result.stderr.trim() ?? 'konsistent process failed')
  }

  const diagnostics = parseDiagnostics(result.stdout)
  if (diagnostics === null) {
    return infraResult(result.stderr.trim() || result.stdout.trim() || 'could not parse konsistent JSON output')
  }
  if (result.status !== 0 && diagnostics.length === 0) {
    return infraResult(result.stderr.trim() || result.stdout.trim() || 'konsistent check failed without diagnostics')
  }

  const errors = diagnostics.filter(diagnostic => (diagnostic.severity ?? 'error') === 'error')
  const warnings = diagnostics.filter(diagnostic => diagnostic.severity === 'warning')
  const ok = result.status === 0 && errors.length === 0
  const exitCode: ExitCode = ok ? 0 : 1

  const humanLines = ['analyze:structure']
  if (ok) {
    humanLines.push(
      warnings.length === 0
        ? '  No structural convention violations.'
        : `  No structural convention errors (${warnings.length} warning${warnings.length === 1 ? '' : 's'}).`
    )
  } else {
    humanLines.push(`  ${errors.length} structural convention error${errors.length === 1 ? '' : 's'}:`)
    humanLines.push(...diagnostics.map(formatDiagnostic))
  }

  return {
    check: 'structure',
    ok,
    exitCode,
    summary: ok
      ? `PASS (${warnings.length} warning${warnings.length === 1 ? '' : 's'})`
      : `FAIL (${errors.length} error${errors.length === 1 ? '' : 's'})`,
    human: humanLines.join('\n'),
    json: { check: 'structure', ok, exitCode, diagnostics }
  }
}
