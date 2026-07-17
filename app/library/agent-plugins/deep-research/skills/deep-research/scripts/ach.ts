export type Grade = '++' | '+' | '0' | '-' | '--'

export type ACHInput = {
  canonical_prior?: 'naive' | 'historical_conditioned' | 'current_consensus'
  conclusion_scale?: number
  priors: Record<'naive' | 'historical_conditioned' | 'current_consensus', Record<string, number>>
  hypotheses: Array<{ id: string; implies_outcome: boolean; kind?: 'base_rate' | 'mechanism' | 'residual' }>
  evidence: Array<{
    id: string
    source_id: string
    cluster: string
    independence_key: string
    corroborated_by: string[]
    newness: 'new' | 'repeated' | 'unknown'
    absorbed: 'unabsorbed' | 'partially_absorbed' | 'absorbed' | 'unknown'
    horizon_weight: 'full' | 'partial' | 'none'
    grades: Record<string, Grade>
  }>
  assumptions?: Array<{
    id: string
    failure_grades: Record<string, Grade>
  }>
  unresolved_discriminators?: Array<{
    id: string
    outcomes: Array<{ id: string; grades: Record<string, Grade> }>
  }>
}

export type ACHOutput = {
  schema_version: 'ach_output_v1'
  canonical_prior: string
  posterior_by_prior: Record<string, Record<string, number>>
  leading_by_prior: Record<string, string>
  hypothesis_ranking: string[]
  outcome_probability: number
  prior_flip: boolean
  no_edge_candidate: boolean
  recommended_verdict: 'estimate' | 'no_edge'
  loading_clusters: string[]
  loading_evidence_unverified: boolean
  loading_weight_adjustment: 'one_grade_toward_neutral' | 'none'
  evidence_weight_adjustments: Array<{
    evidence_id: string
    reasons: string[]
    applied_grades: Record<string, Grade>
  }>
  sensitivity: Array<{
    cluster: string
    leading_hypothesis: string
    outcome_probability: number
    outcome_delta: number
    flips_leader: boolean
    source_count: number
    independently_verified: boolean
  }>
  assumption_sensitivity: Array<{
    assumption: string
    leading_hypothesis: string
    outcome_probability: number
    outcome_delta: number
    flips_leader: boolean
  }>
  remaining_swing: Array<{
    discriminator: string
    outcomes: Array<{ id: string; outcome_probability: number; leading_hypothesis: string }>
    swing: number
  }>
  max_remaining_swing: number
  information_value_exhausted: boolean
  confidence_bounds: {
    min: 1
    max: number
    independent_clusters: number
    verified_loading_rate: number
    unresolved_discriminators: number
  }
}

const gradeWeight: Record<Grade, number> = { '++': 4, '+': 2, '0': 1, '-': 0.5, '--': 0.25 }
const gradeStrength: Record<Grade, number> = { '++': 2, '+': 1, '0': 0, '-': 1, '--': 2 }
const gradeDirection: Record<Grade, number> = { '++': 1, '+': 1, '0': 0, '-': -1, '--': -1 }
const requiredPriorNames = ['naive', 'historical_conditioned', 'current_consensus'] as const

export function computeACH(input: ACHInput): ACHOutput {
  validateACHInput(input)
  const canonicalPrior = input.canonical_prior ?? 'historical_conditioned'
  const canonicalPriorValue = input.priors[canonicalPrior]
  const rawCanonical = posterior(input, canonicalPriorValue)
  const rawLeader = ranking(rawCanonical)[0]!
  const clusterIDs = [...new Set(input.evidence.map(item => item.cluster))].sort()

  const rawSensitivity = clusterIDs.map(cluster => {
    const values = posterior(withoutCluster(input, cluster), canonicalPriorValue)
    return {
      cluster,
      leading_hypothesis: ranking(values)[0]!,
      outcome_probability: outcomeProbability(input, values),
      flips_leader: ranking(values)[0] !== rawLeader
    }
  })
  const loadingClusters = new Set(rawSensitivity.filter(item => item.flips_leader).map(item => item.cluster))
  const unverifiedLoadingClusters = new Set(
    [...loadingClusters].filter(cluster => clusterIndependentKeys(input, cluster).size < 2)
  )
  const adjustedInput = downgradeUnverifiedLoadingEvidence(input, unverifiedLoadingClusters)
  const posteriors = Object.fromEntries(
    requiredPriorNames.map(name => [name, posterior(adjustedInput, adjustedInput.priors[name])])
  )
  const canonical = posteriors[canonicalPrior]!
  const canonicalLeader = ranking(canonical)[0]!
  const canonicalOutcome = outcomeProbability(adjustedInput, canonical)
  const leaders = Object.fromEntries(Object.entries(posteriors).map(([name, values]) => [name, ranking(values)[0]!]))
  const sensitivity = clusterIDs
    .map(cluster => {
      const values = posterior(withoutCluster(adjustedInput, cluster), canonicalPriorValue)
      const outcome = outcomeProbability(adjustedInput, values)
      const sources = clusterIndependentKeys(input, cluster)
      return {
        cluster,
        leading_hypothesis: ranking(values)[0]!,
        outcome_probability: outcome,
        outcome_delta: round(Math.abs(outcome - canonicalOutcome)),
        flips_leader: ranking(values)[0] !== canonicalLeader,
        source_count: sources.size,
        independently_verified: sources.size >= 2
      }
    })
    .sort(
      (left, right) =>
        Number(right.flips_leader) - Number(left.flips_leader) ||
        right.outcome_delta - left.outcome_delta ||
        left.cluster.localeCompare(right.cluster)
    )
    .slice(0, 3)

  const assumptionSensitivity = (input.assumptions ?? []).map(assumption => {
    const simulated = withSyntheticEvidence(adjustedInput, `assumption:${assumption.id}`, assumption.failure_grades)
    const values = posterior(simulated, canonicalPriorValue)
    const outcome = outcomeProbability(simulated, values)
    return {
      assumption: assumption.id,
      leading_hypothesis: ranking(values)[0]!,
      outcome_probability: outcome,
      outcome_delta: round(Math.abs(outcome - canonicalOutcome)),
      flips_leader: ranking(values)[0] !== canonicalLeader
    }
  })

  const remainingSwing = (input.unresolved_discriminators ?? []).map(discriminator => {
    const outcomes = discriminator.outcomes.map(outcome => {
      const simulated = withSyntheticEvidence(
        adjustedInput,
        `discriminator:${discriminator.id}:${outcome.id}`,
        outcome.grades
      )
      const values = posterior(simulated, canonicalPriorValue)
      return {
        id: outcome.id,
        outcome_probability: outcomeProbability(simulated, values),
        leading_hypothesis: ranking(values)[0]!
      }
    })
    const probabilities = outcomes.map(outcome => outcome.outcome_probability)
    return {
      discriminator: discriminator.id,
      outcomes,
      swing: round(Math.max(...probabilities) - Math.min(...probabilities))
    }
  })
  const maxRemainingSwing = remainingSwing.length
    ? Math.max(...remainingSwing.map(discriminator => discriminator.swing))
    : 0
  const priorFlip = new Set(Object.values(leaders)).size > 1
  const scale = input.conclusion_scale ?? 0.05
  const independentClusters = predictiveIndependenceKeys(adjustedInput).size
  const verifiedLoadingClusters = [...loadingClusters].filter(
    cluster => clusterIndependentKeys(input, cluster).size >= 2
  ).length
  const verifiedLoadingRate = loadingClusters.size === 0 ? 1 : verifiedLoadingClusters / loadingClusters.size
  const unresolvedDiscriminators = remainingSwing.filter(item => item.swing >= scale / 2).length
  const clusterBound = independentClusters < 2 ? 2 : independentClusters < 3 ? 3 : independentClusters < 5 ? 4 : 5
  const confidenceMax = Math.min(
    clusterBound,
    unverifiedLoadingClusters.size > 0 ? 3 : 5,
    unresolvedDiscriminators > 0 ? 3 : 5
  )

  return {
    schema_version: 'ach_output_v1',
    canonical_prior: canonicalPrior,
    posterior_by_prior: posteriors,
    leading_by_prior: leaders,
    hypothesis_ranking: ranking(canonical),
    outcome_probability: canonicalOutcome,
    prior_flip: priorFlip,
    no_edge_candidate: priorFlip || unverifiedLoadingClusters.size > 0,
    recommended_verdict: priorFlip ? 'no_edge' : 'estimate',
    loading_clusters: [...loadingClusters].sort(),
    loading_evidence_unverified: unverifiedLoadingClusters.size > 0,
    loading_weight_adjustment: unverifiedLoadingClusters.size > 0 ? 'one_grade_toward_neutral' : 'none',
    evidence_weight_adjustments: evidenceWeightAdjustments(input, adjustedInput, unverifiedLoadingClusters),
    sensitivity,
    assumption_sensitivity: assumptionSensitivity,
    remaining_swing: remainingSwing,
    max_remaining_swing: round(maxRemainingSwing),
    information_value_exhausted: maxRemainingSwing < scale / 2,
    confidence_bounds: {
      min: 1,
      max: confidenceMax,
      independent_clusters: independentClusters,
      verified_loading_rate: round(verifiedLoadingRate),
      unresolved_discriminators: unresolvedDiscriminators
    }
  }
}

export function validateACHInput(input: ACHInput): void {
  if (!input || typeof input !== 'object') throw new Error('ACH input must be an object')
  if (!Array.isArray(input.hypotheses) || input.hypotheses.length < 3)
    throw new Error('ACH requires at least three hypotheses')
  const hypothesisIDs = new Set(input.hypotheses.map(item => item.id))
  if (hypothesisIDs.size !== input.hypotheses.length || hypothesisIDs.has(''))
    throw new Error('hypothesis ids must be non-empty and unique')
  if (input.hypotheses.some(item => !['base_rate', 'mechanism', 'residual'].includes(item.kind ?? '')))
    throw new Error('every ACH hypothesis requires a valid kind')
  if (!input.hypotheses.some(item => item.kind === 'base_rate')) throw new Error('ACH requires a base_rate hypothesis')
  if (!input.hypotheses.some(item => item.kind === 'residual')) throw new Error('ACH requires a residual hypothesis')
  if (!input.priors || Object.keys(input.priors).sort().join(',') !== [...requiredPriorNames].sort().join(',')) {
    throw new Error('ACH priors must have exactly these keys: naive, historical_conditioned, current_consensus')
  }
  for (const name of requiredPriorNames) {
    const prior = input.priors?.[name]
    if (!prior) throw new Error(`ACH requires the ${name} prior`)
    if (Object.keys(prior).sort().join(',') !== [...hypothesisIDs].sort().join(','))
      throw new Error(`prior ${name} must contain exactly the live hypotheses`)
    const sum = Object.values(prior).reduce((total, value) => total + value, 0)
    if (Math.abs(sum - 1) > 1e-6) throw new Error(`prior ${name} must sum to 1`)
    for (const id of hypothesisIDs) {
      if (!Number.isFinite(prior[id]) || prior[id]! <= 0)
        throw new Error(`prior ${name} is missing positive mass for ${id}`)
    }
  }
  if (input.canonical_prior && !requiredPriorNames.includes(input.canonical_prior))
    throw new Error('canonical_prior must name one of the three required priors')
  if (input.conclusion_scale !== undefined && (!(input.conclusion_scale > 0) || input.conclusion_scale > 1))
    throw new Error('conclusion_scale must be greater than 0 and at most 1')
  const evidenceIDs = new Set<string>()
  for (const evidence of input.evidence ?? []) {
    if (!evidence.id || !evidence.source_id || !evidence.cluster || !evidence.independence_key)
      throw new Error('evidence requires id, source_id, cluster, and independence_key')
    if (evidenceIDs.has(evidence.id)) throw new Error(`duplicate evidence id ${evidence.id}`)
    evidenceIDs.add(evidence.id)
    if (!['new', 'repeated', 'unknown'].includes(evidence.newness))
      throw new Error(`invalid newness for evidence ${evidence.id}`)
    if (!['unabsorbed', 'partially_absorbed', 'absorbed', 'unknown'].includes(evidence.absorbed))
      throw new Error(`invalid absorbed value for evidence ${evidence.id}`)
    if (!['full', 'partial', 'none'].includes(evidence.horizon_weight))
      throw new Error(`invalid horizon_weight for evidence ${evidence.id}`)
    validateGrades(evidence.grades, hypothesisIDs, `evidence ${evidence.id}`)
  }
  const evidenceByID = new Map(input.evidence.map(evidence => [evidence.id, evidence]))
  for (const evidence of input.evidence) {
    if (!Array.isArray(evidence.corroborated_by)) throw new Error(`evidence ${evidence.id} requires corroborated_by`)
    for (const corroboratorID of evidence.corroborated_by) {
      if (corroboratorID === evidence.id) throw new Error(`evidence ${evidence.id} cannot corroborate itself`)
      if (!evidenceByID.has(corroboratorID))
        throw new Error(`evidence ${evidence.id} references unknown corroborator ${corroboratorID}`)
    }
  }
  for (const cluster of new Set(input.evidence.map(evidence => evidence.cluster))) {
    const keys = new Set(
      input.evidence.filter(evidence => evidence.cluster === cluster).map(evidence => evidence.independence_key)
    )
    if (keys.size > 1) throw new Error(`cluster ${cluster} must use one originating independence_key`)
  }
  const clusterByOrigin = new Map<string, string>()
  for (const evidence of input.evidence) {
    const existingCluster = clusterByOrigin.get(evidence.independence_key)
    if (existingCluster && existingCluster !== evidence.cluster) {
      throw new Error(
        `independence_key ${evidence.independence_key} must belong to one cluster, not ${existingCluster} and ${evidence.cluster}`
      )
    }
    clusterByOrigin.set(evidence.independence_key, evidence.cluster)
  }
  const assumptionIDs = new Set<string>()
  for (const assumption of input.assumptions ?? []) {
    if (!assumption.id) throw new Error('assumption requires id')
    if (assumptionIDs.has(assumption.id)) throw new Error(`duplicate assumption id ${assumption.id}`)
    assumptionIDs.add(assumption.id)
    validateGrades(assumption.failure_grades, hypothesisIDs, `assumption ${assumption.id}`)
  }
  const discriminatorIDs = new Set<string>()
  for (const discriminator of input.unresolved_discriminators ?? []) {
    if (!discriminator.id || discriminator.outcomes.length !== 2)
      throw new Error('each unresolved discriminator requires exactly two named outcomes')
    if (discriminatorIDs.has(discriminator.id)) throw new Error(`duplicate discriminator id ${discriminator.id}`)
    discriminatorIDs.add(discriminator.id)
    if (new Set(discriminator.outcomes.map(outcome => outcome.id)).size !== discriminator.outcomes.length)
      throw new Error(`discriminator ${discriminator.id} outcome ids must be unique`)
    for (const outcome of discriminator.outcomes) {
      if (!outcome.id) throw new Error(`discriminator ${discriminator.id} outcome requires id`)
      validateGrades(outcome.grades, hypothesisIDs, `discriminator ${discriminator.id}/${outcome.id}`)
    }
  }
}

function posterior(input: ACHInput, prior: Record<string, number>): Record<string, number> {
  const scores = Object.fromEntries(
    input.hypotheses.map(hypothesis => [hypothesis.id, Math.log(prior[hypothesis.id] ?? 0)])
  )
  for (const cluster of new Set(input.evidence.map(item => item.cluster))) {
    const entries = input.evidence.filter(item => item.cluster === cluster)
    for (const hypothesis of input.hypotheses) {
      const strongest = strongestGrade(entries.map(item => effectiveGrade(item, hypothesis.id)))
      scores[hypothesis.id]! += Math.log(gradeWeight[strongest])
    }
  }
  const max = Math.max(...Object.values(scores))
  const weights = Object.fromEntries(Object.entries(scores).map(([id, score]) => [id, Math.exp(score - max)]))
  const total = Object.values(weights).reduce((sum, value) => sum + value, 0)
  return Object.fromEntries(Object.entries(weights).map(([id, value]) => [id, round(value / total)]))
}

function strongestGrade(grades: Grade[]): Grade {
  const strength = Math.max(...grades.map(grade => gradeStrength[grade]))
  const strongest = grades.filter(grade => gradeStrength[grade] === strength)
  if (new Set(strongest.map(grade => gradeDirection[grade])).size > 1) return '0'
  return strongest.sort((left, right) => gradeWeight[right] - gradeWeight[left])[0] ?? '0'
}

function downgradeUnverifiedLoadingEvidence(input: ACHInput, clusters: Set<string>): ACHInput {
  if (clusters.size === 0) return input
  return {
    ...input,
    evidence: input.evidence.map(evidence =>
      clusters.has(evidence.cluster)
        ? {
            ...evidence,
            grades: Object.fromEntries(
              Object.entries(evidence.grades).map(([id, grade]) => [id, downgradeGrade(grade)])
            )
          }
        : evidence
    )
  }
}

function downgradeGrade(grade: Grade): Grade {
  return ({ '++': '+', '+': '0', '0': '0', '-': '0', '--': '-' } as const)[grade]
}

function effectiveGrade(evidence: ACHInput['evidence'][number], hypothesisID: string): Grade {
  if (evidence.absorbed === 'absorbed' || evidence.horizon_weight === 'none') return '0'

  let grade = evidence.grades[hypothesisID] ?? '0'
  if (evidence.newness !== 'new') grade = downgradeGrade(grade)
  if (evidence.absorbed !== 'unabsorbed') grade = downgradeGrade(grade)
  if (evidence.horizon_weight === 'partial') grade = downgradeGrade(grade)
  return grade
}

function evidenceWeightAdjustments(
  original: ACHInput,
  adjusted: ACHInput,
  unverifiedLoadingClusters: Set<string>
): ACHOutput['evidence_weight_adjustments'] {
  const adjustedByID = new Map(adjusted.evidence.map(evidence => [evidence.id, evidence]))
  return original.evidence.flatMap(evidence => {
    const reasons: string[] = []
    if (evidence.newness === 'repeated') reasons.push('repeated_information')
    if (evidence.newness === 'unknown') reasons.push('unknown_newness')
    if (evidence.absorbed === 'absorbed') reasons.push('already_absorbed')
    if (evidence.absorbed === 'partially_absorbed') reasons.push('partially_absorbed')
    if (evidence.absorbed === 'unknown') reasons.push('unknown_absorption')
    if (evidence.horizon_weight === 'none') reasons.push('outside_horizon')
    if (evidence.horizon_weight === 'partial') reasons.push('partial_horizon')
    if (unverifiedLoadingClusters.has(evidence.cluster)) reasons.push('unverified_loading_cluster')
    if (reasons.length === 0) return []

    const adjustedEvidence = adjustedByID.get(evidence.id) ?? evidence
    return [
      {
        evidence_id: evidence.id,
        reasons,
        applied_grades: Object.fromEntries(
          original.hypotheses.map(hypothesis => [hypothesis.id, effectiveGrade(adjustedEvidence, hypothesis.id)])
        )
      }
    ]
  })
}

function predictiveIndependenceKeys(input: ACHInput): Set<string> {
  return new Set(
    input.evidence
      .filter(evidence => input.hypotheses.some(hypothesis => effectiveGrade(evidence, hypothesis.id) !== '0'))
      .map(evidence => evidence.independence_key)
  )
}

function withoutCluster(input: ACHInput, cluster: string): ACHInput {
  return { ...input, evidence: input.evidence.filter(item => item.cluster !== cluster) }
}

function withSyntheticEvidence(input: ACHInput, id: string, grades: Record<string, Grade>): ACHInput {
  return {
    ...input,
    evidence: [
      ...input.evidence,
      {
        id,
        source_id: id,
        cluster: id,
        independence_key: id,
        corroborated_by: [],
        newness: 'new',
        absorbed: 'unabsorbed',
        horizon_weight: 'full',
        grades
      }
    ]
  }
}

function clusterIndependentKeys(input: ACHInput, cluster: string): Set<string> {
  const evidenceByID = new Map(input.evidence.map(evidence => [evidence.id, evidence]))
  const keys = new Set<string>()
  for (const evidence of input.evidence.filter(item => item.cluster === cluster)) {
    keys.add(evidence.independence_key)
    for (const corroboratorID of evidence.corroborated_by) {
      const corroborator = evidenceByID.get(corroboratorID)
      if (corroborator) keys.add(corroborator.independence_key)
    }
  }
  return keys
}

function outcomeProbability(input: ACHInput, values: Record<string, number>): number {
  return round(
    input.hypotheses
      .filter(hypothesis => hypothesis.implies_outcome)
      .reduce((sum, hypothesis) => sum + (values[hypothesis.id] ?? 0), 0)
  )
}

function ranking(values: Record<string, number>): string[] {
  return Object.entries(values)
    .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))
    .map(([id]) => id)
}

function validateGrades(grades: Record<string, Grade>, ids: Set<string>, label: string): void {
  if (!grades || Object.keys(grades).sort().join(',') !== [...ids].sort().join(','))
    throw new Error(`${label} grades must contain exactly the live hypotheses`)
  for (const id of ids) if (!(grades?.[id] in gradeWeight)) throw new Error(`invalid grade for ${label}/${id}`)
}

function round(value: number): number {
  return Number(value.toFixed(6))
}
