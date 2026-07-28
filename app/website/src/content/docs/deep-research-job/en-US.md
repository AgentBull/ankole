---
title: Run long research with Deep Research
description: Move multi-source research to a Background Agent Job that uses pluggable research methods and delivers a sourced report after independent review.
section: Guides
order: 302
---

Deep Research is for literature reviews, competitor research, multi-source fact checking, forecasts that must compare several explanations, and reviews of earlier forecasts against known outcomes. This work needs repeated search, reading, and cross-checking. The Agent moves it to a [Background Agent Job](../background-jobs/) and continues to handle your other messages.

This is not the same as a search of some web pages and a summary. The Job works in stages in its own durable workspace: it plans, then collects in parallel and writes the material into source notes, then derives its conclusions from that evidence, then gives the report to a verifier that cannot see the research process, and last audits the report against each success criterion. Serious research usually needs 30–90 minutes. When you only need a quick answer, ask directly and do not use Deep Research.

## Before you start

Complete [Quick start](../quickstart/) and confirm that the Agent can reply in your chat channel. Configure the `web_search` and `web_fetch` model profiles when the Agent must search public web pages.

A Job can use an Ankole LLM Provider or a configured [ChatGPT subscription account](../codex-accounts/). Select the runtime in **Console → Agents → Background Agent Jobs**.

The Job automatically receives every Skill that is enabled for the Agent and permitted in Background Agent Jobs. When your instance enables a data-source Skill, for example a financial data interface or an internal system connection, the Job uses that data before it searches the public web. You do not authorize the Job separately.

## Start the research

State the subject, time range, evidence rules, and output format. Ask for background execution:

```text
Run this as a Deep Research Background Agent Job.
Compare the pricing and product updates from these three vendors over the last
two quarters. Cite primary sources, separate facts from inference, and return
a report with links. Ask me before you expand the scope or use paid data.
```

### Clarification before creation

The Agent does not start work from one sentence. Before it creates the Job, it interviews you about each unresolved research choice: the goal and its use, the success criteria, the scope and time boundary, the evidence rules, and the deliverable. It asks one question at a time and gives its recommended answer. It looks up the facts that the environment can supply and brings only real decisions to you. The Job is created only after you confirm.

These few minutes are worth their cost. A wrong research direction wastes the next 60 minutes of collection and analysis, but one sentence resolves a question.

When you do not want the interview, say "Stop asking, create the Job directly, and decide the rest yourself." The Agent then states the assumptions it made for you and the choices it leaves to the Job, and creates the Job.

### What a good request contains

A defined scope is more useful than "research this deeply." The report gets closer to what you need when the request states these items:

- **The subject and the question to answer**, not only a topic. "Analyze the renewable energy industry" and "Which of these three vendors is more likely to cut prices in the next two quarters, and on what evidence?" produce very different reports.
- **The time range and the information cutoff.** In a review or a reconstruction of an earlier judgment, this item decides whether the Job can use information that became available later.
- **The evidence rules**: primary sources only, citations required, and facts separate from inference.
- **The analysis method**, when you want one. For example, ask for a comparison of competing hypotheses with ACH, or for a forward-looking analysis that uses historical cases. The Job selects a method itself when you do not name one.
- **The deliverable and its language.** The default is a Markdown report. When you request PDF, PPT, or a web page, the Job delivers only that format, unless you also ask for the Markdown source, and applies the Agent's `DESIGN` visual rules when you do not specify a style.
- **The boundaries**: budget, paid data sources, scope expansion, and the deadline.

A stated length is an approximate target: "a 3-page PDF" means about 3 pages unless you ask for an exact value.

## How the Job works

Knowledge of the Job's internal method helps you read its progress, judge the trust the result deserves, and know what to ask. Each Deep Research Job moves through four stages in its own durable workspace.

### 1. Plan

The Job first lists the Playbooks available in the workspace and reads the methods that apply to the question. When the scope is broad, the subject is not yet clear, or related facts can have changed after the model's knowledge, the Job sends one sub-Agent to make a quick exploration. This exploration does not collect evidence and does not make conclusions. It establishes the current meaning and boundary of the subject, and finds the key concepts, research dimensions, search terms, and data sources that the model can omit.

The Job then prepares a detailed collection plan. Exploration comes before planning so that the plan starts from current facts and not from an older version of the world in the model's memory.

### 2. Collect the evidence

Several sub-Agents execute the collection plan in parallel. All useful material becomes a Markdown note under `sources/`, with YAML at the start of the file for the origin, publication time, author, confidence, and link. All later analysis cites these notes and not a temporary impression from one search.

Collection obeys one ownership rule: each data source and each primary document has one owner. The owner collects it one time and writes the result to a file. The other sub-Agents read that file and do not repeat the request. The Job downloads one announcement, filing, or dataset one time only, and names the file with its identifier so that a later sub-Agent can find it. When a tool accepts a list, the Job asks for the whole batch in one call.

Data from an enabled Skill comes before a public web search. The Job reads the Skill documentation first and uses `web_search` or `web_fetch` only for what no Skill supplies, or after a Skill call shows that the data is absent. It does not read a public website to replace data that must come from a data interface. What a Skill cannot supply becomes a recorded evidence gap in `sources/`, not a silent omission.

Not all information comes from retrieval. When necessary, the Job writes a script to process upstream raw data and derives the values it needs from structured data. After the first organization, the Job examines whether information is still missing, whether some information conflicts, and whether the context that the later analysis needs is complete. It then collects more as necessary.

### 3. Analyze and verify

Conclusions must follow step by step from the available information and form a closed chain of logic. The Job does not select a judgment first and then look for support. The report separates facts, opinions, hypotheses, and inference. When the current evidence permits more than one interpretation, the Job lists all of them, states which one it prefers, and gives its confidence. It keeps a healthy skepticism about news and marketing claims, and works against confirmation bias, sampling bias, and the narrative fallacy while it writes.

An independent verifier then reviews the analysis. This verifier inherits no conversation turns and does not receive the Job's private working state. It gets only the report and your research purpose. It reviews both form and substance. For form, it checks whether the report separates facts, opinions, and hypotheses, gives sufficient citations, and gives you conclusions with real information value. For substance, it reviews the report adversarially: whether the logic is internally consistent, whether other explanations are possible, whether the report reverses causality, and whether it sets the target after it shoots the arrow.

The verifier advises and does not own the final judgment. Each material disagreement either changes the affected analysis and report, or stays visible in the report with its reason. A disagreement is not flattened into an apparent agreement.

### 4. Deliver

Delivery starts with a criteria audit: the report must account for every success criterion. It satisfies the criterion with cited evidence, or states the criterion as an open gap together with the consequence for the conclusions. When a gap defeats the research purpose and time permits, the Job collects more evidence that it can still reach. A late report can fail its purpose as surely as an incomplete one.

The Job then produces the deliverable in the format you requested and gives it to one sub-Agent for a light final check. The report uses your language, follows George Orwell's six rules for writing, and adds no disclaimers.

### Working state, recovery, and restart

The Job keeps its private working state in `research-state.md` in the workspace: each success criterion with its current status, the candidate conclusions with the open gaps in their support, the rejected directions with their reasons, and the unresolved concerns about the validity of the collected information. This file is working memory and not a deliverable. No verifier receives it, because independent review must form its own view and must not follow the researcher's reasoning.

The file lets progress survive. After a Worker interruption or a loss of context, the Job continues from this file and does not explore again what is already settled.

When the Job finds during the research that the frame is wrong — a misidentified subject, a misread question, or a broken core assumption — it does not patch the analysis. It records the corrected frame in `research-state.md`, discards the analysis that the wrong frame invalidates, and does the affected stages again. It keeps the collected `sources/` and re-collects only what the corrected frame makes insufficient. A report built on a wrong frame wastes the whole Job, so a restart is cheaper than it looks.

## Playbooks: pluggable research methods

A Playbook is a method file in the `playbooks/` directory of the Job workspace, distributed with the workspace template of the deep-research Agent Plugin. Each Playbook declares at its start when it applies. During planning, the Job lists all Playbooks and reads the relevant ones.

A Playbook is more than added advice. It can replace the default analysis, verification, and report order with its own protocol, as ACH does with the default single-pass review. The methodology is therefore replaceable and extensible: the research method is a file, and it is not fixed in the model or in the code.

Two general methods are built in.

### ach: Analysis of Competing Hypotheses

When information is incomplete, conflicting, or possibly deceptive, an important forecast or diagnosis must compare several reasonable explanations. ACH makes that comparison explicit and the judgment auditable. It does not improve poor evidence and does not calculate the answer for you.

A fact lookup with only one meaningful answer does not need ACH. When reliable data and a suitable statistical or causal model can answer the question, use that model and do not treat ACH as a substitute.

**Hypotheses come before the evidence.** The Job first states the exact question, the information cutoff, and, for a forecast, the horizon and the outcome definition. It then generates all reasonable hypotheses before it evaluates the evidence. This order prevents the first plausible explanation from defining the whole analysis. Each hypothesis answers the same question at the same level over the same period, and the Job states whether the hypotheses are mutually exclusive and whether they cover the reasonable possibilities. There is no required hypothesis count: a hypothesis stays until the comparison gives a reason to revise it, because lack of support is not disproof.

**The evidence goes into a matrix that a tool can check.** The Job keeps one `competing-hypotheses.yaml` file that owns the cross-hypothesis comparison. Each row is one proposition that can be assessed against every hypothesis: an observation, a reported claim, an expected but absent signal, an analytical assumption, a logical argument, or a base rate. Each row records its real type, its source paths or analytical basis, and the source's qualifications — a source that says that something is alleged does not establish it as fact. The Job then runs the structure check:

```bash
bun tools/ach_check.ts
```

The checker finds only structural omissions and unsafe or missing local source paths. It does not judge whether a hypothesis is plausible, whether a proposition is true, whether a source supports it, or whether a relation is correct. The tool owns what a machine can check; the judgment stays with the model and with you.

**The comparison uses diagnosticity, not the quantity of support.** For each row, the Job asks how expected this information would be if the hypothesis were true, and not whether the information proves the hypothesis. It uses only six relations — expected, compatible, tension, contradicts, unknown, and not applicable — each with a short rationale. It reads across a row before it reads down a hypothesis, because diagnosticity comes from the differences inside one row. Information that is compatible with every hypothesis can be important, but it does little to separate them.

**Dependence and channel coverage.** Copied reports are one information origin. Several indicators produced by one event, or several results derived from one dataset, are also not independent support. Correlated rows can preserve useful detail, but they cannot create independent support. Channel coverage is easier to miss: different hypotheses show themselves in different channels, and if the evidence for one hypothesis lives in a channel that nobody searched, the comparison measures your search coverage and not the world. Each hypothesis therefore names the channel in which it would appear, and the Job collects from that channel or records a coverage gap.

**Absent signals and linchpins.** An absence becomes negative evidence only when the expected signal was observable and the search could reasonably have found it. The Job also identifies the few linchpin items and assumptions that drive the result, and tests each one: how the judgment changes if that item is false, misleading, incomplete, dependent on another item, or produced deliberately to deceive. Confidence in the whole judgment depends on hypothesis coverage, evidence quality, dependence, and sensitivity, and not on the volume of collected material.

**Three-pass verification with progressive disclosure.** ACH replaces the default review with its own protocol. The same verifier makes three passes, and the order is the protection:

1. **Pass A: independent reconstruction from the sources.** The verifier receives only your research purpose, the exact ACH question, the information cutoff, and access to `sources/`. It does not see the matrix, the report, the researcher's preferred hypothesis, or the researcher's reasoning. It identifies the plausible hypotheses, the most diagnostic information, the relation of each item to each hypothesis, and the linchpins, and it records its own tentative assessment. It also identifies absent signals, hidden assumptions, source dependencies, cutoff leakage, possible deception, and the next observations that would separate the alternatives.
2. **Pass B: comparison with the matrix.** Only after the verifier records its own reconstruction does it receive `competing-hypotheses.yaml`. It compares the two analyses, traces source-backed statements to their notes, inspects the original material for each linchpin and disputed row, and reports specific defects with their reasons.
3. **Pass C: review of the report.** After all Pass B discrepancies are handled, the report is written from the matrix and given to the same verifier. It checks that the report presents the relative assessment, the diagnostic information, the counterevidence, the unresolved issues, and the confidence basis and limits faithfully.

What protects the reconstruction is the order, not a different verifier: the matrix is disclosed only after the verifier records its own reconstruction. A verifier that sees the conclusion first makes it an anchor.

**The matrix does not become a probability.** A qualitative matrix produces no posterior probability. Its labels are not likelihoods, and its row counts are not probabilities. When the report gives a number, it distinguishes an explicitly subjective estimate from a calculated Bayesian result, and a Bayesian calculation needs a coherent partition of the possibilities or an explicit joint model, priors, conditional likelihoods, and a treatment of evidence dependence.

**Insufficient evidence is a finding, but not an exit.** It is the cheapest judgment to defend, so it can absorb an analysis that the available evidence could have decided. When the comparison cannot separate the hypotheses, the report states what that means for you, what it costs if a rejected hypothesis is true, and which observation would separate them. Further research is selected for its power to separate the hypotheses, not for the quantity of information it can add.

### analogical-foresight: historical cases for a forward-looking analysis

Historical cases can supply mechanisms, variables, and tests for a forward-looking analysis. The unit of analogical analysis is a transfer claim:

```text
supported source-case mechanism -> specific target mapping
  -> conditions required for transfer -> target-side observation
```

History is evidence only when this chain is complete. Surface similarity and a persuasive historical story do not establish that the same mechanism operates in the target.

**Frame the target before you name a case.** The Job states the target question, the information cutoff, the horizon, and the current stage, collects sufficient target information, and then sketches the target structure before it names any historical case: the observed preconditions, event sequences, constraints, and outcomes so far; the inferred causal relations with the evidence for each inference; and the unknown factors and unexplained stages that could change the analysis. In the opposite order, a vivid case defines the problem for you. In a reconstructed forecast, later target events cannot select the cases, define the target structure, or judge the mappings.

**Generate candidates from the causal gaps.** Candidate cases come from the uncertain relations, missing factors, and unexplained stages in the target frame. The Job searches for the same directed relation, causal dynamic, or functional constraint across different actors, periods, and domains, and generates candidates before it evaluates them so that the first familiar case does not end the search. When the candidate pool stays inside one familiar domain or repeats one historical story, the Job can ask a context-isolated sub-Agent that sees only the target frame to propose cross-domain cases, failed cases, and cases with reversed outcomes. That sub-Agent generates candidates; it does not judge the target.

**Establish the source-case mechanism first.** An event sequence is not yet a causal explanation. The Job verifies the facts of each retained case, identifies the evidence that supports the claimed mechanism, and checks whether a common cause, an alternative mechanism, chance, selection effects, or a later narrative can explain the same sequence. An alias, a subevent, a superset, or another description of the same episode cannot give independent support. A case with a reversed relation, a failed transfer, a different stage, or a broken boundary condition stays useful as a counterexample or as evidence of the mechanism's limits.

**Audit each transfer claim.** Every analogy-derived claim that can affect the answer keeps six parts together: the source mechanism with its evidence; the specific target relation to which it is mapped; the material differences in preconditions, roles, direction, timing, scale, scope, and incentives; the transfer assumptions; the dependencies, such as shared sources, nested events, common shocks, policy copying, common institutions, or common measurement; and a target-side observation that could support or weaken the transfer. For the behavior of an actor, the analysis uses that actor's own goals, constraints, incentives, information, and decision process; your own expected behavior in the same position is not evidence about that actor. A retained case must contribute at least one candidate mechanism, missing variable, conditional path, target-side indicator, counterexample, or boundary condition. A case that contributes only a historical narrative is removed.

**Check dependence before you combine cases.** Several independently informative cases can reduce reliance on one historical story, but they still do not show that the mechanism operates in the target. The Job examines whether an apparent repetition comes from the same episode, institution, source narrative, shock, propagation path, policy diffusion, or measurement method. When a positive pattern matters, it also looks for cases in which the proposed factor was present but the outcome was absent, or the outcome occurred through another mechanism. A purposefully selected analogy set is not a reference class, so its case count is not a base rate, a probability, or a confidence level.

**"No defensible analogy" is a permitted conclusion.** The analysis is complete only when every analogy-derived claim that affects the answer identifies its mechanism and the evidence that distinguishes it from material alternative explanations; the specific relation mapped to the target with its direction, stage, and scope; the material differences, dependencies, and transfer conditions; and a target-side observation that could support or weaken it. Every discovered counterexample or failed mapping is accounted for. If no candidate can satisfy the transfer chain, the correct conclusion is that no defensible analogy was found, and not a persuasive case that stays in the report.

### The two methods work together

They solve different problems and can connect inside one research task. An analogy can propose an ACH hypothesis or identify the evidence to seek, and ACH then makes the diagnostic comparison between those hypotheses. A historical case is not a direct observation of the target; it supports a target claim only through an explicit and defensible transfer claim.

### Add a Playbook for your domain

A private deployment can add its own method files to the workspace template, for example an internal due-diligence procedure, an industry data-source catalog, or the review criteria for one kind of decision. A file becomes discoverable with a `name` and a `description` field. New Jobs see it automatically during planning and read it when the question is relevant. You do not change the model or the code.

## While the Job runs

The current chat remains available after the Agent creates the Job. You can keep talking to the Agent, and you can open **Console → Background Agent Jobs** to inspect the plan, progress, model use, and current status.

When the Job needs a decision, it asks in the original conversation. Reply there so it can continue. `waiting_on_user` means that the Job needs your answer. It is not a failure. You can also add material or correct the requirements in the original conversation at any time; the main Agent forwards them to the Job.

## Read the result

When the Job completes, the main Agent reads the report before it delivers the result. When the report states a gap or limitation that harms the research purpose, the Agent tells you. When the missing part is information the Agent holds, or a decision from you, it supplies that to the Job and lets the Job continue, instead of forwarding a report that does not serve its purpose.

Examine these points in the report: whether the sources support the conclusions, whether the time range is correct, whether facts stay separate from inference, and whether the report states its gaps and confidence honestly. The report must be self-contained, so that you understand the conclusions, evidence, limits, and uncertainty without other files. To examine one piece of evidence, ask the Agent to read the related source note from the Job workspace. After an ACH analysis, you can also ask for the rationale of one row in the hypothesis matrix.

Ask the Agent to continue the same Job when you need more work; you do not need to describe the full background again. If the Job fails or remains queued, open its details and read the status or error. See [Background Agent Jobs](../background-jobs/) for status meanings, cancellation, and runtime settings.

## References and how Ankole differs

The design of Ankole Deep Research agrees with the public research below, and that work also gave us ideas. Each paper reports state-of-the-art results on its own benchmark. Our question is different: what makes these principles hold inside a private enterprise deployment.

- Chen, Y., Chen, G., Sun, Y., & Zhang, K. (2026). <a href="https://arxiv.org/abs/2607.13602" target="_blank" rel="noreferrer">Analogical Deep Research: Retrieving and Integrating Historical Analogies for Foresight Analysis</a>. arXiv:2607.13602.
- Zhu, C., Xu, B., Du, M., Wang, S., Wang, X., Mao, Z., & Zhang, Y. (2026). <a href="https://arxiv.org/abs/2602.01566" target="_blank" rel="noreferrer">FS-Researcher: Test-Time Scaling for Long-Horizon Research Tasks with File-System-Based Agents</a>. arXiv:2602.01566.
- MiroMind Team. (2026). <a href="https://arxiv.org/abs/2603.15726" target="_blank" rel="noreferrer">MiroThinker-1.7 & H1: Towards Heavy-Duty Research Agents via Verification</a>. arXiv:2603.15726.

**The method is a file, not model training.** CANA is an agentic framework. MiroThinker improves the reliability of each step with an agentic mid-training stage and builds verification into the model's own reasoning process. Both come with the model. We write the research method into Playbook files in the workspace, the Job reads them during planning, and a Playbook can replace the default review protocol. The cost is that execution quality depends on how well the model follows instructions. The benefit is that a change of model needs no retraining, and a private deployment can add or remove methods for its own domain. That is the normal case in enterprise research, where the real difference lives in the industry method and the internal data sources, not in general capability.

**Independence comes from information control, not from self-audit.** MiroThinker audits its own reasoning trajectory during inference. Our verifier inherits no conversation turns, does not receive `research-state.md`, and under ACH must first reconstruct the comparison from `sources/` alone. Only then does it see the matrix, and last the report. The reason is direct: an audit of your own trajectory carries the same priors that produced it, and a verifier that sees the conclusion first makes it an anchor.

**Persistence sits in the Job lifecycle, not only outside the context window.** FS-Researcher uses the file system to work beyond the context window, and our source notes and workspace agree with that completely. The difference is that our workspace belongs to a Background Agent Job with a lease, recovery, later messages, and a wait state for your answer. The Job continues after the Worker stops, and not only after the context overflows. We also do not use a fixed librarian-and-writer split: writing needs the complete analysis chain, and a hard split turns the report into a restatement of the notes. On the collection side we use the ownership rule of one owner for each data source, and we enforce isolation only for the verifier.

**An analogy must give a falsifiable transfer chain.** ADR shows that models find analogies by surface features instead of the underlying mechanism, and proposes mechanism alignment and cross-analogy confirmation. We agree, and our analogical-foresight Playbook turns this into a transfer chain that must be complete. It adds two requirements. Dependence is checked before cases are combined, because repetition that comes from one shock, one source narrative, or one measurement method looks like confirmation and is not. And every transfer claim must give a target-side observation, so that the analogy can be proved wrong later instead of only sounding convincing in the report.

**The endpoint is your confirmed purpose, not a benchmark score.** The papers optimize against benchmarks. We optimize for what one person will do with this report: the success criteria are clarified before creation, audited one by one before delivery, and each gap states its consequence; when a gap defeats the purpose, the main Agent supplies what it can and lets the Job continue. Collection follows the same rule, because enabled Skill data sources come before public search and a gap that no Skill can fill is recorded as an evidence gap. A usable enterprise report depends on whether it used authoritative data and stated honestly what it could not do, and neither item appears on a general benchmark score sheet.

The Playbooks, the verification protocols, the research state file, and the delivery audit in the workspace are designed and implemented by the AgentBull Ankole team.
