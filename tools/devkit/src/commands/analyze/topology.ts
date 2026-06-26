// `analyze topology` — public-surface usage reports. The `unused-public-surface`
// report is a CI gate for the scopes in TOPOLOGY_GATED_SCOPES (internal module
// surfaces must not export what nothing consumes); every other scope/report
// combination is report-only (exitCode 0 unless the analyzer itself fails).
// Glue rewritten for Ankole around the ported ts-topology lib; named scopes
// come from config.

import { repoRootPath } from '../../utils'
import { DEFAULT_TOPOLOGY_SCOPE, TOPOLOGY_GATED_SCOPES, TOPOLOGY_SCOPES, TOPOLOGY_UNUSED_ALLOWLIST } from './config'
import { analyzeTopology } from './lib/ts-topology/analyze'
import { renderTextReport } from './lib/ts-topology/reports'
import { createFilesystemPublicSurfaceScope } from './lib/ts-topology/scope'
import type { TopologyReportName } from './lib/ts-topology/types'
import type { CheckResult } from './types'

const VALID_REPORTS: ReadonlySet<TopologyReportName> = new Set([
  'public-surface-usage',
  'owner-map',
  'single-owner-shared',
  'unused-public-surface',
  'consumer-topology'
])

export interface TopologyOptions {
  json?: boolean
  scope?: string
  report?: string
  limit?: number
  excludeTests?: boolean
}

function infraResult(message: string): CheckResult {
  return {
    check: 'topology',
    ok: false,
    exitCode: 2,
    summary: 'ERROR (topology analysis failed)',
    human: `analyze:topology\n  ${message}`,
    json: { check: 'topology', ok: false, exitCode: 2, error: message }
  }
}

export function runTopology(options: TopologyOptions = {}): CheckResult {
  const scopeId = options.scope ?? DEFAULT_TOPOLOGY_SCOPE
  const scopeConfig = TOPOLOGY_SCOPES[scopeId]
  if (!scopeConfig) {
    return infraResult(`unknown scope '${scopeId}' (valid: ${Object.keys(TOPOLOGY_SCOPES).join(', ')})`)
  }
  const report = (options.report ?? 'public-surface-usage') as TopologyReportName
  if (!VALID_REPORTS.has(report)) {
    return infraResult(`unknown report '${report}' (valid: ${[...VALID_REPORTS].join(', ')})`)
  }
  const gated = report === 'unused-public-surface' && (TOPOLOGY_GATED_SCOPES as readonly string[]).includes(scopeId)
  const limit = options.limit ?? 25
  const intentionalUnusedPublicExportNames = new Set(
    TOPOLOGY_UNUSED_ALLOWLIST.filter(entry => entry.scope === scopeId).map(entry => entry.exportName)
  )

  try {
    const scope = createFilesystemPublicSurfaceScope(repoRootPath, {
      id: scopeId,
      description: scopeConfig.description,
      entrypointRoot: scopeConfig.entrypointRoot,
      importPrefix: scopeConfig.importPrefix
    })
    const envelope = analyzeTopology({
      repoRoot: repoRootPath,
      scope,
      report,
      includeTests: !options.excludeTests,
      intentionalUnusedPublicExportNames,
      limit,
      tsconfigName: 'app/agent_computer/tsconfig.json'
    })
    const unusedSummary =
      envelope.totals.allowlistedUnused > 0
        ? `${envelope.totals.unused} unused, ${envelope.totals.allowlistedUnused} allowlisted`
        : `${envelope.totals.unused} unused`
    const ok = !gated || envelope.totals.unused === 0
    const exitCode = ok ? 0 : 1
    const mode = gated ? 'gate' : 'report-only'
    return {
      check: 'topology',
      ok,
      exitCode,
      summary: `${ok ? (gated ? 'OK' : 'report') : 'FAIL'} (${scopeId}: ${envelope.totals.exports} exports, ${unusedSummary}) [${mode}]`,
      human: `analyze:topology [${mode}]\n${renderTextReport(envelope, limit)}`,
      json: { check: 'topology', ok, exitCode, scope: scopeId, report, envelope }
    }
  } catch (error) {
    return infraResult(error instanceof Error ? error.message : String(error))
  }
}
