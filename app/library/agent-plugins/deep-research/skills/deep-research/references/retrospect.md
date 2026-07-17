# Forecast retrospect mode

The Job input section names the immutable, hash-verified forecast report snapshot under `inputs/source_forecast_report/report`. It also supplies either an explicit boolean result or an instruction to resolve it under the original rule. Do not create a replacement forecast. Read that snapshot directly; copying or archiving it again is optional working state.

If resolving live, cite the decisive outcome source in the report. If an explicit result is supplied, identify it as user-supplied rather than inventing an external citation.

The outcome is either `resolved` with a boolean or `unable_to_determine` with `actual_outcome: null`. An ambiguous rule is itself a process finding; never force a boolean to make scoring convenient.

Put the complete retrospective in `report/report.md` and audit five areas with source citations where the finding depends on external evidence:

1. resolution under the original rule;
2. hypothesis survival, including discarded hypotheses that fit better in hindsight and ignored falsifiers;
3. evidence weights and `newness`/`absorbed`/`horizon_weight` labels;
4. calibration reflection: prior, weighting, or update-timing error, without claiming population calibration from one case;
5. lessons in `situation -> attention` form, each proposed for `brain` or `skill` parent review.

Include the resolution status, actual outcome when resolved, hypothesis postmortem, evidence audit, missed falsifiers, calibration reflection, Brier score when computable, and lessons in the Markdown report. Lessons are proposals; do not write Brain or skills. Optional JSON notes do not substitute for any of this content. Use native subagents for a fresh factual or report challenge when useful.
