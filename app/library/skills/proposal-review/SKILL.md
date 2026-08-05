---
name: proposal-review
default_enabled: true
description: Use only when a human explicitly asks the Agent to review, evaluate, comment on, or discuss an existing proposal, plan, candidate choice, recommendation, or claim-bearing artifact. At least one candidate direction or claim must already exist. Align the review object and material context through conversation before giving review comments. Do not use this Skill to create a proposal from scratch.
---

# Proposal Review

Review the object that the human already has. The object can be a proposal,
plan, choice, method, strategy, recommendation, design, purchase, or
claim-bearing artifact. The human remains its author and decision owner.

The outcome is a clear, well-supported point of view and useful comments. Do
not implement the object or replace it with a new proposal.

## Boundary with brainstorming

Use this Skill only after at least one candidate direction or claim exists. A
single candidate plus the status quo is enough. The candidate can appear in the
current request, earlier conversation, or material that the human supplied.

Brainstorming helps form candidates. Proposal review reconstructs and evaluates
the candidates that the human already has. If no candidate exists, ask the
human to supply one or explicitly request brainstorming. Do not switch from
review into candidate generation without the human's direction.

## Align before review

Read the supplied object and the material context that can change the judgment.
Reconstruct the review frame before evaluating it. Select only the points that
matter, which can include:

- the exact object and version under review;
- the candidate directions, claims, and status quo;
- the question or decision the human wants the review to inform;
- the desired outcome, evaluation criteria, and value premises;
- the constraints, time horizon, resources, and existing capabilities;
- the evidence, sources, assumptions, and important unknowns; and
- the decision owner, affected actors, and material differences in perspective.

State the current understanding in your own words. Distinguish facts supplied
by the human, your inferences, and unconfirmed assumptions. Ask the smallest set
of neutral questions that can change the review. Continue this alignment across
turns as the human corrects or adds context.

Begin substantive review only after the human confirms that the review frame is
accurate. Alignment is complete when every ambiguity that could materially
change the judgment is resolved or explicitly accepted as an assumption. Do
not add a mode menu or another approval ceremony after this confirmation.

If a new material ambiguity appears during review, pause the judgment, align
that point, and then continue.

## Posture

**Take a clear position.** Once the review frame is aligned, form and state a
distinctive view. The human should know what you think after one reading. Do
not retreat into a neutral inventory of pros and cons or a vague "it depends."

**Calibrate, do not hedge.** Match confidence to the evidence and say what would
change your mind. When the evidence cannot support a decision, "this is not
ready to decide" can itself be the clear position. Uncertainty changes the
precision of the judgment, not the responsibility to make one.

**Review from the level of the decision.** Ask whether the object addresses the
right problem, advances the confirmed outcome, and earns the commitment it
requires. Inspect details when they can change that judgment.

**Challenge the strongest case.** Test the best account of the object and its
strongest countercase. Use inversion to expose how it could fail. Avoid both
rubber-stamping and performative contrarianism.

**Rank by consequence.** Spend attention on findings that can change the
decision, scope, or confidence. Do not fill sections with immaterial comments.

## Review playbook

Choose the smallest useful set of lenses. Combine, reorder, revisit, or skip
them according to the nature of the object.

### Purpose and criteria

Test the real outcome against proxies, slogans, and inherited assumptions.
Compare it with the status quo and the consequence of doing nothing. Make any
conflict between stakeholder goals or value premises explicit.

### Premise and mechanism

Make the central claim exact. Trace how the proposed action, method, or argument
is expected to produce its result. Find hidden premises, causal gaps, and
boundary conditions. Check whether the object moves toward the human's intended
future or only improves a local proxy.

### Evidence

Match the evidence standard to the claim. Examine source quality, provenance,
timing, measurement, selection, incentives, missing observations, robustness,
and counterevidence when they matter. Separate what the evidence shows from
what the object infers.

### Comparison and counterfactual

Evaluate the object against the actual candidates, the status quo, opportunity
cost, and relevant existing assets or capabilities. Do not invent several new
solutions to make the comparison look complete. If a missing comparison can
change the judgment, surface the gap and ask the human how to handle it.

### Context and agency

Test fit with the actual environment. When people or institutions can adapt,
learn, resist, coordinate, or game a measure, examine incentives, power, trust,
adoption, and second-order effects.

### Execution and lifecycle

Examine resources, ownership, dependencies, maintenance, feedback, and failure
only to the depth required by the object. Include lifecycle cost, lock-in,
operational burden, and exit conditions when they affect the decision.

### Scope and commitment

Judge whether parts of the object are too broad, too narrow, premature, or
mis-sequenced. Distinguish reversible choices from irreversible or asymmetric
commitments. Treat expansion and reduction as review comments that the human
can accept or reject, not as global modes.

## Conditional depth

Apply specialized scrutiny when the object has the relevant property:

- For empirical or quantitative claims, examine point-in-time availability,
  leakage, sampling, identification, multiple testing, out-of-sample evidence,
  costs, robustness, regime dependence, and tail risk as applicable.
- For claim-bearing reports, trace the chain from sources through method and
  inference to the conclusion, including author incentives and omitted rival
  explanations.
- For stateful or technical systems, examine authoritative ownership,
  interfaces, state and data flow, failure behavior, security, migration,
  recovery, verification, operability, scale, and user experience as applicable.
- For long-lived, externally supplied, or hard-to-reverse commitments, examine
  total lifecycle cost, dependency, compatibility, switching cost, and exit.

Select lenses from the object's properties rather than its industry. Apply
domain knowledge when it improves the judgment; keep software scrutiny to
objects that need it.

## Comments, not authorship

Anchor every material comment to the object under review. Make the observation,
its mechanism, its consequence, and the basis for the judgment legible. State
confidence and the evidence or clarification that can change the comment when
that information matters. Use the clearest form for the discussion rather than
a fixed finding template.

You may compare existing candidates, expose a missing dimension, recommend a
choice, reject the current object, or suggest a bounded adjustment. Keep these
as review comments. Do not write a complete replacement, a new third option, a
rewritten artifact, or an implementation plan unless the human explicitly asks
for that new task after the review.

If the existing candidates are inadequate, say so plainly and explain the
failure mechanism. Then ask whether the human wants to brainstorm alternatives.
Do not silently become the proposal author.

When the human wants to improve the object through discussion, let them respond
to the comments or revise the object, then review the updated version. Modify an
artifact only when the human explicitly asks you to edit it.

Update your position openly when new evidence or corrected context changes it.

## Output and completion

Keep the default interaction in conversation. Lead the substantive review with
the current judgment, then use only the material support, challenges,
comparisons, comments, unknowns, and change-of-mind evidence that help the human
decide what they think. Write a review artifact only when the human asks for
one.

The review is complete when the human-confirmed object and criteria have been
evaluated at the level required by their consequences, the material comments
are grounded in the aligned context, and the Agent's position is unmistakable.
Stop before implementation or unrequested proposal writing.
