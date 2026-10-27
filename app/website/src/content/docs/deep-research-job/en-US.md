---
title: Run long research with Deep Research
description: Move multi-source research to a Background Agent Job that uses pluggable research methods and delivers a sourced report after independent review.
section: Guides
order: 302
---

Use Deep Research for literature reviews, competitor intelligence, multi-source fact-checking, forecasts that weigh competing explanations, and post-mortems comparing earlier forecasts against known outcomes. Because that work requires iterative search, close reading, and cross-checking, the Agent delegates it to a [Background Agent Job](../background-jobs/) while staying free to handle your other messages.

Deep Research goes far beyond searching a few web pages and summarizing snippets. Working in stages inside its own durable workspace, the Job plans the investigation, collects primary material in parallel into structured source notes, derives conclusions strictly from that evidence, hands the draft to a context-isolated verifier that cannot see the research process, and finally audits the report against every success criterion. Serious runs typically take 30–90 minutes—when you only need a quick answer, ask in chat directly rather than launching Deep Research.

## Before you start

Complete [Quick start](../quickstart/) and verify that your Agent replies in chat, then configure the `web_search` and `web_fetch` model profiles if the Agent will search public web pages.

Every Job routes model calls through AIGateway. To draw on ChatGPT subscription capacity, set up a [ChatGPT subscription provider](../chatgpt-subscription-provider/) and bind it under **Console → Agents → Background Agent Jobs**.

Each Job automatically inherits every Skill enabled for the Agent that supports Background Agent Jobs. Whenever an authoritative data-source Skill is enabled—such as a financial market feed or an internal system connector—the Job queries that Skill before falling back to public web search, with no extra per-Job authorization required.

## Start the research

State the subject, time range, evidence rules, and deliverable format, and ask to run the task in the background:

```text
Run this as a Deep Research Background Agent Job.
Compare the pricing and product updates from these three vendors over the last
two quarters. Cite primary sources, separate facts from inference, and return
a report with links. Ask me before you expand the scope or use paid data.
```

### Clarification before creation

Rather than launching a 60-minute run from a single ambiguous sentence, the Agent interviews you briefly before creating the Job to settle any open research choices: your goal and intended use, success criteria, scope and time cutoff, evidence rules, and output deliverable. After looking up whatever context the environment already supplies, the Agent asks one question at a time alongside its recommended default, creating the Job only once you confirm.

Spending two minutes upfront saves an hour of wasted collection and analysis down the wrong path. If you want to skip the interview, say `"Stop asking, create the Job directly, and decide the rest yourself"`—the Agent will state the assumptions that it made on your behalf, note what it left to the Job, and start immediately.

### What a good request contains

Specific constraints produce far sharper reports than `"research this deeply"`:

- **The subject and the concrete question to answer**, not just a broad topic—`"Analyze the renewable energy industry"` and `"Which of these three vendors is most likely to cut prices over the next two quarters, and on what evidence?"` yield completely different investigations.
- **The time range and information cutoff**—especially in retrospectives or forecast reconstructions, where this rule determines whether the Job may consult events published after the cutoff date.
- **The evidence rules**—such as primary sources only, mandatory citations, and strict separation between facts and inference.
- **The analysis method**, if you want a specific framework—for example, comparing rival explanations via ACH or grounding a forward-looking forecast in historical cases. If you omit one, the Job picks an appropriate Playbook automatically.
- **The deliverable format and language**—Markdown by default. When you ask for a PDF, slide deck (PPT), or web page, the Job delivers that format alone unless you also ask for the Markdown source, applying the Agent's `DESIGN` visual system whenever you specify no custom theme.
- **Operational guardrails**—budget, paid data sources, scope expansion rules, and your deadline.

Treat requested page counts as approximate targets (`"a 3-page PDF"` aims for roughly three pages unless you specify a hard limit).

## How the Job works

Understanding the Job's internal workflow helps you read its live progress, calibrate how much trust the final report deserves, and steer it mid-flight. Every Deep Research Job moves through four stages inside its durable workspace.

### 1. Plan

First, the Job lists the Playbooks in its workspace and reads those matching your question. Whenever the scope is broad, the subject is unfamiliar, or key facts may have shifted since the model's training cutoff, the Job sends a sub-Agent on a brief scoping pass—not to gather evidence or draw conclusions, but to map current terminology, subject boundaries, research dimensions, search terms, and authoritative sources that the model might otherwise overlook.

Only after scoping does the Job write its collection plan, grounding the plan in how the domain looks today rather than stale model priors.

### 2. Collect the evidence

Multiple sub-Agents execute the collection plan in parallel, saving every useful finding as a Markdown note under `sources/` with YAML frontmatter recording its origin, publication timestamp, author, confidence, and URL. Downstream analysis cites those persisted notes rather than fleeting search-snippet impressions.

Collection enforces a strict single-owner rule: each data source and each primary document is assigned to a single sub-Agent, fetched once, and saved under an identifier-based filename so sibling sub-Agents read the local file instead of repeating requests. Whenever an upstream tool accepts a batch of IDs or queries, the Job fetches the batch in one call.

Enabled Skill data sources always come ahead of public web search: the Job reads relevant Skill docs first and uses `web_search` or `web_fetch` only for questions that no Skill covers or after a Skill query confirms the data is absent—never scraping a public web page in place of an authoritative API. Anything a Skill cannot supply is logged explicitly as an evidence gap in `sources/` rather than dropped silently.

Where raw datasets need calculation, the Job writes scripts to process structured data directly. After its initial pass, the Job audits what is still missing, contradictory, or underspecified for the analysis stage, running targeted follow-up collection where needed.

### 3. Analyze and verify

Every conclusion must step logically from cited notes in a closed reasoning chain—the Job never picks a thesis first and cherry-picks support afterward. Throughout the draft, the Job separates verified facts, attributed opinions, working hypotheses, and analytical inferences; when the evidence supports multiple interpretations, it lays out each alternative, names its preferred reading, and states its confidence while guarding against confirmation bias, sampling bias, marketing spin, and narrative fallacy.

Next, a context-isolated verifier reviews the draft. Receiving only the report and your stated research purpose—with zero access to conversation turns or the researcher's private working state—the verifier checks both form and substance. On form, it verifies that facts, opinions, and hypotheses stay distinct, citations support claims, and conclusions carry genuine decision value; on substance, it challenges the report adversarially for internal contradictions, overlooked explanations, reversed causality, or post-hoc target-drawing.

The verifier advises rather than overriding the researcher: every substantive critique either updates the analysis and report or remains explicitly documented in the report alongside why the researcher disagreed—disagreements are never smoothed over into false consensus.

### 4. Deliver

Before formatting the final output, the Job runs a criteria audit accounting for every success criterion—either satisfying it with cited evidence or flagging it as an open gap alongside its impact on the conclusions. If an unresolved gap undermines the core research purpose and time remains before your deadline, the Job runs targeted collection to close it, weighing completeness against timeliness since an overdue report can miss its decision window just like an incomplete one.

Finally, the Job renders your requested format in your language, hands it to a sub-Agent for a final polish check, follows George Orwell's six rules for clear writing, and omits boilerplate disclaimers.

### Working state, recovery, and restart

Throughout execution, the Job maintains its private working memory in `research-state.md`: the live status of each success criterion, candidate conclusions and their remaining evidence gaps, rejected hypotheses and why they failed, and open source-credibility questions. `research-state.md` is never delivered to you and never shown to the verifier, preserving independent review.

Persisting `research-state.md` also makes long runs resilient: after a Worker replacement or context compaction, the Job resumes straight from that file without re-exploring settled ground.

If mid-run evidence reveals that the initial framing itself was flawed—a misidentified entity, a misread question, or a broken core premise—the Job refuses to paper over the flaw. Instead, it writes the corrected frame into `research-state.md`, discards invalid downstream analysis, and re-runs the affected stages while reusing valid notes in `sources/` and collecting only what the new frame requires.

## Playbooks: pluggable research methods

Playbooks are Markdown method specifications under `playbooks/` in the Job workspace, seeded from the `deep-research` Agent Plugin's workspace template. Each Playbook declares upfront when it applies; during planning, the Job scans `playbooks/` and loads any matching method.

More than stylistic tips, a Playbook can override the default analysis, verification, and reporting workflow—for instance, replacing single-pass verification with ACH's three-pass progressive disclosure. Because methodology lives in plain workspace files rather than model weights or hardcoded Elixir/TypeScript, teams can evolve or add methods freely. Two general Playbooks ship built in.

### ach: Analysis of Competing Hypotheses

Whenever evidence is incomplete, conflicting, or potentially deceptive, high-stakes diagnoses and forecasts need a structured comparison across rival explanations. Analysis of Competing Hypotheses (ACH) makes that comparison explicit and auditable—though it neither rescues weak evidence nor computes probabilities on its own, and straightforward factual lookups or questions solvable with a direct statistical/causal model should use those directly instead.

**Hypotheses come before the evidence.** Before evaluating evidence, the Job defines the exact question, information cutoff, and (for forecasts) horizon and outcome criteria, then enumerates all plausible hypotheses at a consistent level of specificity—stating whether they are mutually exclusive and collectively exhaustive. Generating hypotheses upfront prevents the first plausible story from anchoring the entire run, and no arbitrary cap prunes hypotheses early because absence of support is not disproof.

**The evidence goes into a matrix that a tool can check.** Cross-hypothesis evaluation lives in `competing-hypotheses.yaml`, where each row captures one proposition assessed across every hypothesis—an observation, attributed claim, expected-but-absent signal, analytical assumption, logical argument, or base rate—recording its exact type, local source paths or analytical basis, and source caveats (an allegation in press coverage is not an established fact). The Job validates matrix structure with:

```bash
bun tools/ach_check.ts
```

`ach_check.ts` catches structural omissions and missing or unsafe source paths, leaving substantive judgment—whether hypotheses are sound, sources prove claims, or cell labels hold up—to the model and to you.

**The comparison uses diagnosticity, not the quantity of support.** Across each row, the Job asks how expected that item would be *if each hypothesis were true*—assigning one of six relations (`expected`, `compatible`, `tension`, `contradicts`, `unknown`, or `not applicable`) with a concise rationale. Reading across rows before reading down columns highlights diagnostic power: evidence compatible with every hypothesis may matter contextually while doing nothing to separate rival explanations.

**Dependence and channel coverage.** Syndicated articles trace back to one origin, and multiple metrics from a single event or dataset do not count as independent confirmation. Even subtler is channel coverage: rival hypotheses leave footprints in different places, so failing to search the channel where a hypothesis would appear measures your search blind spots rather than the world. Every hypothesis therefore names its expected observable channels, and the Job either searches them or logs an explicit coverage gap.

**Absent signals and linchpins.** Missing evidence counts against a hypothesis only when the expected signal would have been observable and your collection pass could reasonably have found it. The Job also isolates the handful of linchpin items and assumptions driving its conclusion and stress-tests how the ranking shifts if any linchpin turns out to be false, incomplete, correlated, or planted. Overall confidence reflects hypothesis coverage, source quality, independence, and linchpin sensitivity—never raw note count.

**Three-pass verification with progressive disclosure.** ACH replaces single-pass review with a three-pass protocol run by a single context-isolated verifier, where disclosure order prevents anchoring:

1. **Pass A: independent reconstruction from the sources.** Given only your research purpose, the exact ACH question, the cutoff date, and `sources/`—with `competing-hypotheses.yaml`, the draft report, and the researcher's preferred hypothesis withheld—the verifier independently maps plausible hypotheses, diagnostic items, cell relations, linchpins, absent signals, hidden assumptions, source dependencies, cutoff leaks, deception risks, and tie-breaking future observations.
2. **Pass B: comparison with the matrix.** Only after committing Pass A does the verifier receive `competing-hypotheses.yaml`, comparing both analyses, auditing original source notes behind every linchpin and disputed cell, and returning concrete defect findings.
3. **Pass C: review of the report.** Once Pass B defects are resolved and the report is drafted from the matrix, the same verifier checks that the text faithfully conveys relative rankings, diagnostic evidence, counterevidence, open uncertainties, and confidence bounds.

Withholding the matrix until Pass A is recorded prevents the researcher's conclusion from anchoring the reviewer.

**The matrix does not become a probability.** Qualitative cell labels and row counts are neither likelihoods nor posterior probabilities. Whenever a report states numeric probabilities, it distinguishes explicit subjective probability judgments from formal Bayesian posteriors (which require a coherent hypothesis partition or joint model, explicit priors, conditional likelihoods, and dependency handling).

**Insufficient evidence is a finding, but not an exit.** Because “more research needed” is always easy to defend, undisciplined runs can hide behind uncertainty even when existing evidence separates the alternatives. When evidence genuinely cannot separate rival hypotheses, the report states the practical stakes for your decision, the downside if a dismissed hypothesis holds true, and which specific observation would separate them—selecting any follow-up work for diagnostic leverage rather than volume.

### analogical-foresight: historical cases for a forward-looking analysis

Historical cases strengthen forward-looking analysis only when linked by a complete, testable **transfer claim**:

```text
supported source-case mechanism -> specific target mapping
  -> conditions required for transfer -> target-side observation
```

Surface resemblance or a vivid historical story alone never proves that the same causal mechanism operates in your target situation.

**Frame the target before you name a case.** Before naming any historical precedent, the Job defines the target question, cutoff date, horizon, and current stage, gathers baseline target facts, and maps the target's causal structure—observed preconditions, sequence of events, constraints, inferred causal links with supporting evidence, and key unknowns. Reversing that order lets a memorable historical analogy hijack how you frame the problem (and in reconstructed forecasts, post-cutoff target outcomes may never guide case selection or mapping).

**Generate candidates from the causal gaps.** Starting from the uncertain links and unexplained stages in the target frame, the Job searches across eras, actors, and industries for matching causal dynamics or structural constraints, generating a broad candidate pool before evaluating any single case so the first familiar precedent does not halt search early. If candidates cluster inside one industry or cliché narrative, the Job dispatches a context-isolated sub-Agent (given only the structural target frame) to surface cross-domain precedents, failed transfers, and reversed-outcome cases.

**Establish the source-case mechanism first.** Chronology alone is not causation: for each candidate case, the Job verifies historical facts, checks the evidence for the claimed causal mechanism, and tests whether common shocks, alternative mechanisms, chance, survivorship bias, or retrospective storytelling explain the outcome instead. Aliases, sub-episodes, or retellings of the same historical event never count as independent cases, whereas cases with reversed outcomes or broken preconditions remain valuable for mapping boundary limits.

**Audit each transfer claim.** Every retained analogy keeps six elements together: the evidenced source mechanism; the exact target relation mapped; material differences in preconditions, actor roles, direction, timing, scale, and incentives; required transfer assumptions; cross-case dependencies (shared sources, nested events, common macro shocks, policy imitation, shared institutions, or shared metrics); and a concrete target-side indicator that would confirm or refute the transfer. Actor analysis always models that actor's own goals, constraints, information, and incentives rather than projecting what you would do in their shoes, and any historical case offering only narrative color without a mechanism, variable, indicator, or boundary test is cut.

**Check dependence before you combine cases.** Multiple independent precedents reduce reliance on a single historical anecdote without proving the mechanism holds in the target—so the Job checks whether seeming parallels stem from one underlying shock, policy wave, institution, or source narrative, and actively seeks negative cases where the same causal factor appeared without producing the outcome. Because purposefully chosen analogies do not form a statistical reference class, case counts never translate into base rates or probabilities.

**"No defensible analogy" is a permitted conclusion.** Every analogy-backed claim in the final report must document its distinguished source mechanism, exact target mapping, material differences and dependencies, transfer conditions, and falsifiable target-side indicator, while accounting for counterexamples. If no historical candidate satisfies that full chain, the report concludes plainly that no defensible analogy held rather than padding the text with a superficially persuasive story.

### The two methods work together

Analogical foresight and ACH complement each other cleanly inside a single run: historical analogies can surface candidate hypotheses or observable indicators to look for, while ACH tests those hypotheses diagnostically against one another—treating historical parallels never as direct target facts, only as explicit transfer claims.

### Add a Playbook for your domain

Private deployments can drop custom Markdown Playbooks into the workspace template—such as internal M&A due-diligence checklists, proprietary data-source catalogs, or domain review rubrics. Adding `name` and `description` frontmatter makes a Playbook automatically discoverable during planning on new Jobs without touching model weights or application code.

## While the Job runs

Once the Agent creates the Job, your chat stays open for other work while **Console → Background Agent Jobs** shows the live plan, turn progress, token usage, and status.

Whenever the Job needs a decision from you, it posts the question in the originating conversation and enters `waiting_on_user` (a normal pause, not an error)—reply in that same thread to resume it, or send new source material and course corrections there at any time so the main Agent forwards them to the running Job.

## Read the result

When the Job finishes, the foreground Agent reviews the report before presenting it to you: if an open gap undermines your stated goal and the Agent already holds the missing context (or can ask you for a quick decision), it feeds that context back and resumes the Job rather than handing over an unusable draft.

When reviewing the final report, verify that cited sources back the conclusions, cutoff dates held, facts stay distinct from inference, and uncertainties are stated plainly. Every report is written to stand on its own without requiring external scratch files, though you can always ask the Agent to pull a specific `sources/` note or explain any row's rationale in `competing-hypotheses.yaml`.

To build on finished research, ask the Agent to continue the existing Job so it keeps the full workspace context without re-explaining background. If a Job stalls in `queued` or fails, inspect its status and error on **Console → Background Agent Jobs**; see [Background Agent Jobs](../background-jobs/) for status definitions, cancellation, and concurrency settings.

## References and how Ankole differs

Ankole Deep Research builds on ideas from recent open research—each achieving strong benchmark results—while adapting those ideas to the constraints of a private enterprise deployment:

- Chen, Y., Chen, G., Sun, Y., & Zhang, K. (2026). <a href="https://arxiv.org/abs/2607.13602" target="_blank" rel="noreferrer">Analogical Deep Research: Retrieving and Integrating Historical Analogies for Foresight Analysis</a>. arXiv:2607.13602.
- Zhu, C., Xu, B., Du, M., Wang, S., Wang, X., Mao, Z., & Zhang, Y. (2026). <a href="https://arxiv.org/abs/2602.01566" target="_blank" rel="noreferrer">FS-Researcher: Test-Time Scaling for Long-Horizon Research Tasks with File-System-Based Agents</a>. arXiv:2602.01566.
- MiroMind Team. (2026). <a href="https://arxiv.org/abs/2603.15726" target="_blank" rel="noreferrer">MiroThinker-1.7 & H1: Towards Heavy-Duty Research Agents via Verification</a>. arXiv:2603.15726.

**The method is a file, not model training.** Where CANA provides an agentic framework and MiroThinker bakes verification into model weights through agentic mid-training, Ankole expresses research methodology as workspace Playbook files read at planning time and able to swap out the verification protocol itself. While execution quality still depends on instruction-following, switching models requires zero retraining, and enterprise teams can add proprietary domain methods and internal data sources directly—where real enterprise differentiation lives.

**Independence comes from information control, not from self-audit.** Rather than asking a model to critique its own reasoning trace—which inherits the same priors that produced the draft—Ankole withholds conversation history and `research-state.md` from the verifier, and under ACH requires the verifier to reconstruct hypotheses and diagnostic evidence from `sources/` alone before ever seeing `competing-hypotheses.yaml` or the report, preventing conclusion anchoring.

**Persistence sits in the Job lifecycle, not only outside the context window.** Like FS-Researcher, Ankole persists structured `sources/` notes on disk to scale past prompt limits, and pairs that workspace with a full Background Agent Job lifecycle—leases, Worker crash recovery, mid-run steering messages, and slot-free `waiting_on_user` pauses—so runs survive Worker replacements as well as context compaction. Ankole also avoids splitting collection and writing into disconnected librarian/writer roles (since rigorous synthesis requires the full reasoning chain), instead assigning one owner per data source during collection and reserving strict context isolation for the verifier.

**An analogy must give a falsifiable transfer chain.** Building on ADR's finding that models default to surface similarity unless guided toward causal mechanism alignment, Ankole's `analogical-foresight` Playbook enforces a complete transfer chain plus two enterprise safeguards: auditing cross-case dependence (so shared shocks, narratives, or metrics are never mistaken for independent confirmation) and requiring a concrete target-side observable so every analogy can be tested against reality rather than merely sounding persuasive.

**The endpoint is your confirmed purpose, not a benchmark score.** Rather than optimizing for static benchmark rubrics, Ankole optimizes for an actionable decision artifact: clarifying success criteria upfront, preferring authoritative Skill data sources over open-web scraping, logging explicit evidence gaps when data is unavailable, auditing every criterion before delivery, and resuming automatically when the foreground Agent can close a blocking gap.

The Playbooks, verification protocols, `research-state.md` contract, and delivery audit are designed and implemented by the AgentBull Ankole team.
