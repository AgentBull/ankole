import { afterEach, describe, expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { SubagentDelegationResponse } from '../src/lanes/rpc_lane'
import { evaluateDeepResearchArtifacts } from '../src/tools/subagent/research-artifacts'

const roots: string[] = []

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('Deep Research final delivery form check', () => {
  test('accepts a self-contained Markdown report without sidecars or evidence archives', () => {
    const root = fixtureRoot()
    writeFileSync(join(root, 'report/report.md'), '# Answer\n\nThe complete cited answer and its limitations.\n')

    const result = evaluateDeepResearchArtifacts({
      workdir: root,
      mode: 'general',
      delegation: delegation(root),
      outputText: 'Research complete.'
    })

    expect(result.passed).toBe(true)
    expect(result.result).toMatchObject({
      report: '# Answer\n\nThe complete cited answer and its limitations.',
      conclusion: {},
      evidence_stats: {},
      verification: { status: 'formally_valid' }
    })
  })

  test('requires only a non-empty report', () => {
    const root = fixtureRoot()

    const result = evaluateDeepResearchArtifacts({
      workdir: root,
      mode: 'general',
      delegation: delegation(root),
      outputText: 'Research complete.'
    })

    expect(result.passed).toBe(false)
    expect(result.issues).toEqual(['report/report.md is missing or empty'])
    expect(result.feedback).toContain('self-contained report/report.md')
    expect(result.feedback).toContain('Do not repair or create JSON')
  })

  test('does not inspect optional working artifacts', () => {
    const root = fixtureRoot()
    writeFileSync(join(root, 'report/report.md'), '# Complete report\n')
    mkdirSync(join(root, 'evidence'), { recursive: true })
    writeFileSync(join(root, 'report/conclusion.json'), '{not json')
    writeFileSync(join(root, 'evidence/index.json'), '{also not json')

    const result = evaluateDeepResearchArtifacts({
      workdir: root,
      mode: 'general',
      delegation: delegation(root),
      outputText: ''
    })

    expect(result.passed).toBe(true)
    expect(result.result?.conclusion).toEqual({})
  })
})

function fixtureRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'ankole-research-delivery-'))
  roots.push(root)
  mkdirSync(join(root, 'report'), { recursive: true })
  return root
}

function delegation(root: string): SubagentDelegationResponse {
  return {
    request_id: 'request',
    delegation_id: 'delegation',
    agent_uid: 'agent',
    session_id: 'session',
    status: 'running',
    runtime: 'deep_research',
    mode: 'general',
    codex_account_id: 'account',
    title: 'Research',
    task: 'Answer the question.',
    reply_route: {},
    attempts: 1,
    workdir: root
  }
}
