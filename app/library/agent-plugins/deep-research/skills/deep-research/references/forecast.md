# Forecast research mode

Forecast is domain-neutral ACH layered on the general research contract. Use it only for an event with a testable resolution rule. Mechanism judgment belongs to the researcher; probability arithmetic belongs to `ach_update`.

## Resolution and candidate space

Define an explicit horizon and testable resolution rule. Record load-bearing assumptions when they materially affect the answer. Do not invent a resolution rule to force a point forecast.

Identify the plausible mechanism space before ranking. ACH requires mechanism-distinct hypotheses including base-rate and residual alternatives. Preserve live alternatives until evidence gives a defensible reason to eliminate them. Seek evidence that could change the ranking or kill the leader; treat absent expected evidence as diagnostic only when the expectation and observation window are explicit.

## Evidence and deterministic update

Forecast evidence records `newness`, `absorbed`, `horizon_weight`, `cluster`, `source_id`, `independence_key`, `corroborated_by`, and one holistic diagnostic grade per live hypothesis: `++`, `+`, `0`, `-`, or `--`. Grade how much more or less expected the evidence is under each hypothesis. Same-origin material shares an independence key and cluster.

Build the hypothesis-by-evidence matrix from the three priors, live hypotheses, selected evidence, optional assumption-failure grades, unresolved-discriminator outcomes, and conclusion scale. Each selected evidence row grades every live hypothesis. The final report must show the material hypotheses, evidence, and matrix or an equally complete readable representation so the user can inspect how the conclusion follows.

When deterministic arithmetic helps, use `analysis/ach-input.json` as optional working state. Its `priors` object has exactly the keys `naive`, `historical_conditioned`, and `current_consensus`; each maps every live hypothesis ID to positive probability mass summing to 1. Run:

```bash
bun <skill-root>/scripts/ach_update.ts analysis/ach-input.json > analysis/ach-output.json
```

The script applies newness, absorption, horizon, clustering, corroboration, sensitivity, confidence, and remaining-information rules. Do not hand-edit its result. These JSON files are optional computation aids, not delivery requirements. A fresh native subagent can challenge evidence grades without seeing your conclusion; use its findings as advice, not as a mechanical vote.

## Conclusion

Put the question, horizon, resolution rule, verdict, hypothesis ranking, evidence matrix, probability or `no_edge` conclusion, sensitivity, confidence, and important limitations in `report/report.md`. If deterministic working files exist, keep the report consistent with them without making the reader open them.

Use `no_edge` when the evidence cannot discriminate reliably; include a reason and no point estimate. State missing observables instead of fabricating precision.
