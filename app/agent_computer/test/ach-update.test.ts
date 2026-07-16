import { describe, expect, it } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { computeACH, type ACHInput } from '../../library/skills/deep-research/scripts/ach'

describe('@ankole/agent-computer deterministic ACH update', () => {
  it('computes multi-prior posteriors, sensitivity, and loading-evidence flags without model input', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-ach-update-'))
    const inputPath = join(root, 'ach-input.json')
    const scriptPath = join(
      import.meta.dir,
      '..',
      '..',
      'library',
      'skills',
      'deep-research',
      'scripts',
      'ach_update.ts'
    )
    writeFileSync(
      inputPath,
      JSON.stringify({
        canonical_prior: 'historical_conditioned',
        conclusion_scale: 0.05,
        priors: {
          naive: { H1: 0.34, H2: 0.33, H3: 0.33 },
          historical_conditioned: { H1: 0.5, H2: 0.3, H3: 0.2 },
          current_consensus: { H1: 0.2, H2: 0.5, H3: 0.3 }
        },
        hypotheses: [
          { id: 'H1', kind: 'mechanism', implies_outcome: true },
          { id: 'H2', kind: 'base_rate', implies_outcome: false },
          { id: 'H3', kind: 'residual', implies_outcome: false }
        ],
        evidence: [
          {
            id: 'E01',
            source_id: 'SRC01',
            cluster: 'official-signal',
            independence_key: 'official-origin',
            corroborated_by: [],
            newness: 'new',
            absorbed: 'unabsorbed',
            horizon_weight: 'full',
            grades: { H1: '++', H2: '0', H3: '--' }
          },
          {
            id: 'E02',
            source_id: 'SRC02',
            cluster: 'base-rate',
            independence_key: 'base-rate-origin',
            corroborated_by: [],
            newness: 'new',
            absorbed: 'partially_absorbed',
            horizon_weight: 'full',
            grades: { H1: '0', H2: '++', H3: '0' }
          }
        ],
        assumptions: [{ id: 'A01', failure_grades: { H1: '--', H2: '+', H3: '0' } }],
        unresolved_discriminators: [
          {
            id: 'D01',
            outcomes: [
              { id: 'occurs', grades: { H1: '++', H2: '-', H3: '0' } },
              { id: 'does_not_occur', grades: { H1: '--', H2: '+', H3: '0' } }
            ]
          }
        ]
      })
    )

    try {
      const process = Bun.spawn(['bun', scriptPath, inputPath], { stdout: 'pipe', stderr: 'pipe' })
      const [exitCode, stdout, stderr] = await Promise.all([
        process.exited,
        new Response(process.stdout).text(),
        new Response(process.stderr).text()
      ])

      expect(exitCode).toBe(0)
      expect(stderr).toBe('')
      const output = JSON.parse(stdout)
      expect(output).toMatchObject({
        schema_version: 'ach_output_v1',
        canonical_prior: 'historical_conditioned',
        loading_evidence_unverified: true,
        no_edge_candidate: true
      })
      expect(output.hypothesis_ranking).toHaveLength(3)
      expect(Object.keys(output.posterior_by_prior)).toEqual(['naive', 'historical_conditioned', 'current_consensus'])
      expect(output.sensitivity).toHaveLength(2)
      expect(output.loading_weight_adjustment).toBe('one_grade_toward_neutral')
      expect(output.evidence_weight_adjustments).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ evidence_id: 'E01', reasons: ['unverified_loading_cluster'] }),
          expect.objectContaining({ evidence_id: 'E02', reasons: ['partially_absorbed'] })
        ])
      )
      expect(output.assumption_sensitivity).toHaveLength(1)
      expect(output.remaining_swing).toHaveLength(1)
      expect(output.max_remaining_swing).toBeGreaterThan(0)
      expect(output.confidence_bounds).toMatchObject({
        min: 1,
        independent_clusters: 2,
        verified_loading_rate: 0,
        unresolved_discriminators: 1
      })
      expect(output.outcome_probability).toBeGreaterThan(0)
      expect(output.outcome_probability).toBeLessThan(1)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('turns a leader flip across the three declared priors into a no_edge recommendation', () => {
    const input = baseInput()
    input.priors = {
      naive: { H1: 0.6, H2: 0.25, H3: 0.15 },
      historical_conditioned: { H1: 0.25, H2: 0.6, H3: 0.15 },
      current_consensus: { H1: 0.25, H2: 0.15, H3: 0.6 }
    }

    const output = computeACH(input)

    expect(output.prior_flip).toBe(true)
    expect(output.no_edge_candidate).toBe(true)
    expect(output.recommended_verdict).toBe('no_edge')
  })

  it('only treats a loading cluster as verified through a different independence key', () => {
    const input = baseInput()
    input.priors = {
      naive: { H1: 0.44, H2: 0.46, H3: 0.1 },
      historical_conditioned: { H1: 0.44, H2: 0.46, H3: 0.1 },
      current_consensus: { H1: 0.44, H2: 0.46, H3: 0.1 }
    }
    input.evidence = [
      {
        id: 'E01',
        source_id: 'SRC01',
        cluster: 'decisive-signal',
        independence_key: 'origin-a',
        corroborated_by: ['E02'],
        newness: 'new',
        absorbed: 'unabsorbed',
        horizon_weight: 'full',
        grades: { H1: '++', H2: '--', H3: '0' }
      },
      {
        id: 'E02',
        source_id: 'SRC02',
        cluster: 'independent-check',
        independence_key: 'origin-b',
        corroborated_by: ['E01'],
        newness: 'new',
        absorbed: 'unabsorbed',
        horizon_weight: 'full',
        grades: { H1: '0', H2: '0', H3: '0' }
      }
    ]

    const output = computeACH(input)
    const decisive = output.sensitivity.find(item => item.cluster === 'decisive-signal')

    expect(output.loading_clusters).toContain('decisive-signal')
    expect(output.loading_evidence_unverified).toBe(false)
    expect(decisive).toMatchObject({ source_count: 2, independently_verified: true })
  })
})

function baseInput(): ACHInput {
  return {
    canonical_prior: 'historical_conditioned',
    conclusion_scale: 0.05,
    priors: {
      naive: { H1: 0.34, H2: 0.33, H3: 0.33 },
      historical_conditioned: { H1: 0.34, H2: 0.33, H3: 0.33 },
      current_consensus: { H1: 0.34, H2: 0.33, H3: 0.33 }
    },
    hypotheses: [
      { id: 'H1', kind: 'mechanism', implies_outcome: true },
      { id: 'H2', kind: 'base_rate', implies_outcome: false },
      { id: 'H3', kind: 'residual', implies_outcome: false }
    ],
    evidence: []
  }
}
