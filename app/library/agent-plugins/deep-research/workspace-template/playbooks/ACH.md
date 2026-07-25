---
name: ach
description: "Use when an important forecast or diagnosis must compare plausible explanations under incomplete, noisy, conflicting, or possibly deceptive information."
---

# Analysis of Competing Hypotheses

ACH makes the comparison between hypotheses explicit. It improves the
discipline and auditability of a judgment, but it does not improve poor
evidence, calculate an answer, or guarantee a correct conclusion.

## When ACH helps

Use ACH for an important or difficult judgment when two or more reasonable
explanations or outcomes remain possible and the available information is
incomplete, ambiguous, conflicting, or open to deception.

A fact lookup or a question with only one meaningful answer does not need ACH.
When reliable data and a suitable statistical or causal model can answer the
question, use that model instead of treating ACH as a substitute.

## Frame comparable hypotheses

State the exact question, information cutoff, and, for a forecast, the horizon
and outcome definition. Generate the reasonable hypotheses before you evaluate
the evidence. Separate hypothesis generation from evaluation so that the first
plausible explanation does not define the whole analysis.

Each hypothesis must answer the same question at the same level and over the
same period. State whether the hypotheses are mutually exclusive and whether
they cover the reasonable possibilities. Rewrite or split the question when
overlapping or nested hypotheses cannot be compared clearly. If overlap is
intentional, describe it and do not treat the hypotheses as probabilities that
must add to one.

There is no required hypothesis count. Keep a plausible hypothesis until the
comparison gives a reason to revise or reject it; lack of support is not the
same as disproof. A residual or unknown hypothesis is useful only when it has
meaningful observable implications.

For each hypothesis, record:

- what mechanism or explanation it proposes;
- what observations would be expected if it were true; and
- what observations or assumption failures would weaken it.

The frame is ready when every plausible alternative that could materially
change the answer is represented, each hypothesis can be compared with the
same information, and all important overlap or incompleteness is explicit.

## Build the evidence-and-arguments inventory

When you use ACH, keep one canonical `competing-hypotheses.yaml` file in the
working directory. The file owns the cross-hypothesis comparison. Keep source
content in the source notes and narrative conclusions in the report instead of
duplicating them in the matrix.

Use these structural fields in the matrix:

- `hypotheses` is a list in which each hypothesis has a non-empty, unique `id`;
- `rows` is a list in which each row has a non-empty, unique `id`;
- each row has `source_paths`, a non-empty `analytical_basis`, or both;
- `source_paths` contains only project-relative files inside `./sources`;
- each row has a `relations` map with exactly one entry for every live
  hypothesis ID;
- each relation entry has `relation` and a non-empty `rationale`; and
- `judgment.hypothesis_refs` lists only live hypothesis IDs.

The judgment uses a non-empty `confidence_basis` string and a
`confidence_limits` list whose entries are non-empty strings. Do not add another
key that contains `confidence`. The authoritative report owns the final
confidence statement.

Use one active row for one proposition that can be assessed against every live
hypothesis. A row can contain an observation, a reported claim, an expected but
absent signal, an analytical assumption, a logical argument, or a base rate.
Record its real type. Preserve the source's qualifications: a source that says
that something is possible or alleged does not establish it as fact.

For each row, record the source paths or analytical basis and any issue that can
change its use in the comparison:

- source credibility, relevance, access, or possible deception;
- a shared upstream source, common cause, repeated derivation, or other
  dependence on another row;
- the event time, publication time, and time the information became knowable
  when the cutoff matters; and
- for an absent signal, whether it should have been observable, whether the
  relevant channel was searched, and whether concealment remains plausible.

An absence becomes negative evidence only when the expected signal was
observable and the search could reasonably have found it. A base rate needs a
defined reference class and a reason that the target belongs to it. A set of
purposefully selected cases is not a reference class.

Important background can remain in the source notes. If it has audit value but
does not distinguish the hypotheses, move it out of the active matrix and
briefly record the reason in the same YAML file.

Different hypotheses often show themselves in different channels. If one
hypothesis proposes a mechanism whose observations live in a channel you did not
search, the comparison measures your search coverage and not the world. Name the
channel in which each live hypothesis would appear, then collect from it or
record it as a coverage gap in the same YAML file.

The inventory is ready when every active row states one assessable proposition,
preserves its source or analytical status, exposes every known dependency or
cutoff issue that could change its weight, and covers the channel in which each
live hypothesis would show itself.

Before a verifier reads the matrix, run:

```bash
bun tools/ach_check.ts
```

Run it again after a later correction changes the hypotheses, rows, relations,
source paths, or judgment references. The checker detects only structural
omissions and unsafe or missing local source paths. It does not judge whether a
hypothesis is plausible or comparable, whether a proposition is true, whether a
source supports it, whether a relation or rationale is correct, or whether the
judgment follows.

## Compare for diagnosticity

For each row, ask `P(E | H)`: if this hypothesis were true, how expected would
this information be? This is different from asking whether the information
proves the hypothesis or directly estimating `P(H | E)`.

Use only the following qualitative relations, and include a brief rationale for
each one:

- `expected`: the hypothesis specifically predicts the information;
- `compatible`: the information is possible under the hypothesis but is not a
  specific prediction;
- `tension`: the information would be materially surprising if the hypothesis
  were true, but it does not disprove it;
- `contradicts`: reliable information conflicts with a necessary implication of
  the hypothesis;
- `unknown`: the available basis is not sufficient to assess the relation; and
- `not_applicable`: the information does not bear on that hypothesis.

Assess a relation under each hypothesis on its own terms. Another hypothesis
explaining an item better does not by itself make the item inconsistent with
the first hypothesis. Diagnosticity comes from the differences across the
whole row. Information that is expected or compatible under every hypothesis
can be important, but it does little to distinguish them.

Read across each row before you read down a hypothesis. Then assess the total
explanatory burden of each hypothesis. You can use inconsistency counts to find
where that burden may be high, but the counts do not decide the answer. The
rows differ in diagnostic value, credibility, strength, and dependence.

Treat copied reports as one information origin. Also account for less visible
dependence, such as several indicators produced by one event or several results
derived from one dataset. Correlated rows can preserve useful detail, but they
cannot create independent support.

## Refine and form a provisional judgment

Recheck the hypothesis set and the inventory after the first comparison. Merge,
split, rewrite, add, or remove hypotheses when the matrix shows that the frame
is wrong. If all hypotheses conflict with important information, investigate a
missing hypothesis, weak evidence, or incorrect assessments before you choose a
leader.

Identify the few linchpin items and assumptions that drive the result. Test how
the judgment changes if each one is false, misleading, incomplete, dependent
on another item, or deliberately produced to deceive. Distinguish the relative
ordering of the current hypotheses from confidence in the whole judgment. That
confidence depends on hypothesis coverage, evidence quality, dependence, and
sensitivity, not on the volume of collected material.

The provisional judgment must state:

- the relative assessment of every hypothesis that remains plausible;
- the key diagnostic information and linchpin assumptions;
- the strongest counterevidence and the reasons the judgment could be wrong;
- any material unresolved disagreement or missing information; and
- future indicators that would cause an update.

Insufficient evidence is a finding, not an exit. It is the cheapest judgment to
defend, so it can absorb an analysis that the available evidence could have
decided. When the comparison cannot separate the hypotheses, state what follows
for the reader, what it costs if a rejected hypothesis is true, and which
observation would separate them.

Choose further research for its ability to distinguish the remaining
hypotheses, not for the amount of information it can add.

## Verify with progressive disclosure

This verifier protocol replaces the default verifier protocol in `AGENTS.md`.
Before you rely on the matrix in the report, create one verifier subagent with
no inherited conversation turns. Keep the same verifier for all three passes so
it can compare its independent reconstruction with the later material.

Pass A and Pass B can run in one verifier session. What protects the
reconstruction from anchoring is the order, not a separate session: disclose the
matrix only after the verifier has recorded its own reconstruction.

Report a defect when it can change the relative ordering, a linchpin, or a
stated confidence limit. Keep wording, unit-label, and presentation problems in
one list at the end of the pass. They must still be corrected, but they do not
block the comparison and do not need another pass of their own.

### Pass A: Reconstruct from sources

Give the verifier only:

- the user's research purpose and the exact ACH question;
- the information cutoff and forecast horizon, when applicable; and
- access to `./sources`, with instructions to determine which notes are
  relevant to the ACH question.

During this pass, instruct the verifier to read only files under `./sources`,
to start from the organized notes, and to open raw material under
`./sources/raw` only to check a linchpin that it intends to dispute.
Do not expose `competing-hypotheses.yaml`, the report, your preferred
hypothesis, or your reasoning. Ask the verifier to reconstruct the comparison
independently. It must identify the plausible hypotheses, the most diagnostic
information, the expected relation of each item to each hypothesis, the
linchpins, and its own tentative relative assessment. It must also identify
expected but absent signals, hidden assumptions, source dependencies, cutoff
leakage, possible concealment or deception, and the next observations that
would best distinguish the alternatives.

### Pass B: Compare the matrix

After the verifier records its independent reconstruction, give it
`competing-hypotheses.yaml`. Ask it to compare the two analyses, trace
source-backed statements to their source notes, inspect the original material
for every linchpin or disputed row, and report specific defects and their
reasons. It must check for:

- omitted or misframed hypotheses and omitted diagnostic information;
- claims that overstate, misclassify, or lose qualifications from a source;
- relation assessments that reverse conditional reasoning or lack a defensible
  rationale;
- shared origins, dependencies, or repeated derivations treated as independent
  support;
- absent signals whose observability, search coverage, or concealment has not
  been established;
- background information incorrectly treated as diagnostic;
- linchpins whose failure has not been tested; and
- material differences between its independent assessment and the matrix's
  judgment.

Correct the matrix when an objection is valid. When a material disagreement
remains, keep it visible in the affected hypothesis, row, or judgment with the
reason. Rerun `bun tools/ach_check.ts` after a structural correction.

### Pass C: Verify the report

After all Pass B discrepancies have been handled, write or revise
`report/report.md` from the matrix. Give the same verifier the report and the
matrix. Ask it to check that the report faithfully presents the relative
assessment, diagnostic information, counterevidence, unresolved issues,
confidence basis, and confidence limits without adding a conflicting judgment.
It must also check the report's source citations, distinctions between facts,
opinions, and hypotheses, information value, internal logic, causal direction,
and plausible alternative explanations.

If a valid Pass C objection changes the substantive analysis, update the matrix
first and then the report. Repeat Pass C for the changed material.

The verifier supplies an adversarial comparison; it does not own the final
judgment. Do not create a separate verification state file. Verification is
complete only when every material discrepancy from all three passes has changed
the affected artifact or remains visible with a reason.

## Keep Bayesian claims separate

The qualitative matrix does not produce a posterior probability. Its labels
are not likelihoods, and its row counts are not probabilities. If you give a
number, distinguish an explicitly subjective estimate from a calculated
Bayesian result.

A Bayesian calculation needs a coherent partition of the possibilities or an
explicit joint model, priors, conditional likelihoods, and a treatment of
evidence dependence. It also needs a time window when the question is
time-bounded. If the model deliberately omits possible outcomes, state that the
result is conditional on the incomplete hypothesis set. State the basis and
uncertainty of the inputs and test whether plausible changes alter the result.
Do not derive a numeric probability or confidence level from the ACH matrix
alone.
