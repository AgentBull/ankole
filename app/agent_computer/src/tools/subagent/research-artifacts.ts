import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { z } from 'zod'
import { jsonToolResult } from '../../core/tool-result'
import type { AgentTool } from '../../core/types'
import type { DeepResearchMode, SubagentDelegationResponse } from '../../lanes/rpc_lane'
import type { ResearchSourceArchiveRecord } from './research-evidence-archive'

const resultSchemaVersion = 'deep_research_result_v1'
const DeliveryValidationParams = z.object({}).strict()

export type DeepResearchDeliveryValidationResult = {
  passed: boolean
  failureKind?: 'repair_required' | 'system_error'
  errorCode?: string
  issues: string[]
  feedback: string
  result?: JSONObject
}

export type DeepResearchArtifactInput = {
  workdir: string
  mode: DeepResearchMode
  delegation: SubagentDelegationResponse
  outputText: string
  webArchives?: ResearchSourceArchiveRecord[]
  outputSchema?: JSONObject
  budgetCapped?: boolean
}

/**
 * Checks the one user-facing Deep Research artifact. JSON sidecars, source
 * archives, and other working files are deliberately outside completion.
 */
export function evaluateDeepResearchArtifacts(input: DeepResearchArtifactInput): DeepResearchDeliveryValidationResult {
  const report = readReport(input.workdir)
  const issues = report ? [] : ['report/report.md is missing or empty']
  const conclusion = readOptionalJSONObject(input.workdir, 'report/conclusion.json')
  const status = issues.length === 0 ? 'formally_valid' : 'incomplete'
  const result: JSONObject = {
    schema_version: resultSchemaVersion,
    mode: input.mode,
    summary: summaryText(report || input.outputText),
    output_text: input.outputText.trim() || report,
    report,
    conclusion,
    stop_reason: input.budgetCapped ? 'budget_capped' : (stringValue(conclusion.stop_reason) ?? 'completed'),
    evidence_stats: {},
    verification: {
      status,
      ...(issues.length > 0 ? { issues } : {})
    },
    workdir: input.delegation.workdir ?? input.workdir
  }

  if (input.mode === 'forecast') {
    result.dossier = {
      schema_version: 'forecast_dossier_v1',
      analysis: directoryContents(join(input.workdir, 'analysis')),
      report: { report, conclusion }
    }
  }

  if (input.mode === 'retrospect') {
    const brier = brierScore(input.delegation, conclusion)
    if (brier !== undefined) result.calibration = { brier_score: brier }
  }

  if (issues.length > 0) {
    return {
      passed: false,
      failureKind: 'repair_required',
      issues,
      feedback:
        'Write a non-empty, self-contained report/report.md that contains everything the user needs. Do not repair or create JSON, evidence indexes, source archives, or bundles for this check.',
      result
    }
  }

  return { passed: true, issues: [], feedback: '', result }
}

/** Gives the lead Codex session the same report-presence check used at terminal commit. */
export function createResearchDeliveryValidatorTool(
  input: Omit<DeepResearchArtifactInput, 'outputText' | 'webArchives'> & {
    webArchives: () => ResearchSourceArchiveRecord[]
  }
): AgentTool<typeof DeliveryValidationParams, JSONObject> {
  return {
    name: 'research_validate_delivery',
    description:
      'Check only that the authoritative Deep Research result, report/report.md, exists and is non-empty. JSON, evidence indexes, source archives, and other working files are optional and are not inspected.',
    schema: DeliveryValidationParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute() {
      const result = evaluateDeepResearchArtifacts({
        ...input,
        outputText: '',
        webArchives: input.webArchives()
      })
      return jsonToolResult({
        passed: result.passed,
        failure_kind: result.failureKind ?? null,
        issues: result.issues,
        ...(result.feedback ? { repair_instructions: result.feedback } : {})
      })
    }
  }
}

function readReport(workdir: string): string {
  try {
    return readFileSync(join(workdir, 'report/report.md'), 'utf8').trim()
  } catch {
    return ''
  }
}

function readOptionalJSONObject(workdir: string, path: string): JSONObject {
  try {
    const value: unknown = JSON.parse(readFileSync(join(workdir, path), 'utf8'))
    return objectValue(value)
  } catch {
    return {}
  }
}

function directoryContents(root: string): JSONObject {
  if (!existsSync(root)) return {}
  const output: JSONObject = {}
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    if (entry.isFile()) output[entry.name] = readFileSync(join(root, entry.name), 'utf8')
  }
  return output
}

function brierScore(delegation: SubagentDelegationResponse, conclusion: JSONObject): number | undefined {
  const sourceConclusion = objectValue(delegation.source_forecast?.result?.conclusion)
  const estimate = objectValue(sourceConclusion.outcome_estimate)
  const probability = numberValue(estimate.probability)
  const actual = typeof conclusion.actual_outcome === 'boolean' ? Number(conclusion.actual_outcome) : undefined
  if (probability === undefined || actual === undefined) return undefined
  return Number(((probability - actual) ** 2).toFixed(6))
}

function summaryText(value: string): string {
  const text = value.trim()
  return text.length <= 4_000 ? text : `${text.slice(0, 4_000)}...[truncated]`
}

function objectValue(value: unknown): JSONObject {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as JSONObject) : {}
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

function numberValue(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}
