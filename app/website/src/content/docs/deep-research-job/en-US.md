---
title: Run long research with Deep Research
description: Move multi-source research to a Background Agent Job and receive questions and the final report in chat.
section: Guides
order: 302
---

Deep Research is for literature reviews, competitor research, multi-source fact checking, forecasts that must compare different explanations, and reviews of earlier forecasts against known outcomes. This work needs repeated search, reading, and cross-checking. The Agent moves it to a [Background Agent Job](../background-jobs/) and continues to handle your other messages.

Serious research usually needs 30–90 minutes. The Job collects, analyzes, and verifies in several rounds before it writes the report. When you only need a quick answer, ask directly and do not use Deep Research.

## Before you start

Complete [Quick start](../quickstart/) and confirm that the Agent can reply in your chat channel. Configure the `web_search` and `web_fetch` model profiles when the Agent must search public web pages.

A Job can use an Ankole LLM Provider or a configured [ChatGPT subscription account](../codex-accounts/). Select the runtime in **Console → Agents → Background Agent Jobs**.

The Job automatically receives every Skill that is enabled for the Agent and permitted in Background Agent Jobs. When your instance enables a data-source Skill, for example a financial data interface, the Job uses that data before it searches the public web.

## Start the research

State the subject, time range, evidence rules, and output format. Ask for background execution:

```text
Run this as a Deep Research Background Agent Job.
Compare the pricing and product updates from these three vendors over the last
two quarters. Cite primary sources, separate facts from inference, and return
a report with links. Ask me before you expand the scope or use paid data.
```

### Confirm the research request

Before it creates the Job, the Agent interviews you about each unresolved research choice: the goal and its use, success criteria, scope and time boundary, evidence rules, and the deliverable. It asks one question at a time and gives its recommended answer. It looks up facts that the environment can supply and brings only real decisions to you. The Job is created only after you confirm.

When you do not want the interview, say "Stop asking, create the Job directly, and decide the rest yourself." The Agent then states its assumptions and creates the Job.

A defined scope is more useful than "research this deeply." The report gets closer to what you need when the request states:

- the subject and the question to answer, not only a topic;
- the time range and the information cutoff;
- evidence rules: primary sources only, citations required, and facts separate from inference;
- the analysis method when you want one, for example a comparison of competing hypotheses with ACH;
- the deliverable and its language: the default is a Markdown report; when you request PDF, PPT, or a web page, the Job delivers only that format, unless you also ask for the Markdown source, and applies the Agent's `DESIGN` visual rules when you do not specify a style;
- boundaries: budget, paid data sources, scope expansion, and the deadline.

A stated length is an approximate target: "a 3-page PDF" means about 3 pages unless you ask for an exact value.

## How the Job works

Knowledge of the Job's internal method helps you read its progress and judge the trust the result deserves. Each Deep Research Job moves through four stages in its own durable workspace:

1. **Plan.** The Job lists the Playbooks available in the workspace and reads the methods that apply to the question. When necessary, it first runs a quick exploration to confirm the current meaning of the subject, the key concepts, and the data sources. Then it prepares a detailed collection plan.
2. **Collect.** Multiple sub-Agents collect in parallel. All useful material becomes source notes under `sources/` with the origin, publication time, confidence, and link. One owner collects each data source one time, so nothing is fetched twice. Enabled Skill data sources come before public web search.
3. **Analyze and verify.** Conclusions must follow step by step from the evidence. The report separates facts, opinions, hypotheses, and inference, and lists the uncertainty. An independent verifier that has not seen the research process then reviews the report: it traces citations, checks the internal logic, and looks for other explanations. The verifier advises; the researcher owns the final judgment. A disagreement that remains stays visible in the report with its reason.
4. **Deliver.** The Job first audits the report against each success criterion: the report satisfies it with cited evidence, or states it as an open gap together with the consequence for the conclusions. The Job then produces the requested format and runs one light final check.

The Job keeps its private working state in `research-state.md` in the workspace: the success criteria with their status, the candidate conclusions with their open gaps, and the rejected directions with their reasons. After a Worker interruption, the Job continues from this state and does not repeat completed work. When the Job finds that the research frame is wrong — a misidentified subject, a misread question, a broken core assumption — it discards the invalidated analysis and does the affected stages again, but it keeps the collected sources.

## Playbooks: reusable research methods

A Playbook is a method file in the `playbooks/` directory of the Job workspace, distributed with the workspace template of the deep-research Agent Plugin. Each Playbook declares when it applies. The Job reads the relevant Playbooks during planning, and a Playbook can replace the default verification with its own protocol.

Two general methods are built in:

- **ach** (Analysis of Competing Hypotheses). Use it when an important forecast or diagnosis must compare several reasonable explanations and the information is incomplete, conflicting, or possibly deceptive. The Job keeps a matrix of hypotheses against evidence, assesses how expected each item is under each hypothesis, and finds the evidence and assumptions that really separate the explanations. It brings its own three-pass verification: the verifier first reconstructs the comparison from the sources alone, then inspects the matrix for defects, and last checks the report. This order prevents the researcher's conclusion from anchoring the review.
- **analogical-foresight.** Use it when historical cases can supply mechanisms, variables, and tests for a forward-looking analysis. Each analogy must give the full chain: the supported mechanism in the source case, the specific mapping to the target, the conditions the transfer requires, and the observable signal on the target side. A historical story with only surface similarity is not evidence.

You can name a method in the request, for example "compare these three explanations with ACH," or leave the choice to the Job. A private deployment can add its own domain Playbooks to the template, for example internal research methods and industry data-source catalogs. New Jobs see them automatically during planning.

## While the Job runs

The current chat remains available after the Agent creates the Job. You can keep talking to the Agent, and you can open **Console → Background Agent Jobs** to inspect the plan, progress, model use, and current status.

When the Job needs a decision, it asks in the original conversation. Reply there so it can continue. `waiting_on_user` means that the Job needs your answer. It is not a failure. You can also add material or correct the requirements in the original conversation at any time; the main Agent forwards them to the Job.

## Read the result

When the Job completes, the main Agent reads the report before it delivers the result. When the report states a gap or limitation that harms the research purpose, the Agent tells you. When the missing part is information the Agent holds, or a decision from you, it supplies that to the Job and lets the Job continue.

Check that sources support the conclusions, the time range is correct, and facts are separate from inference. The report must be self-contained. To examine one piece of evidence, ask the Agent to read the related source note from the Job workspace. Ask the Agent to continue the same Job when you need more work; you do not need to describe the full background again.

If the Job fails or remains queued, open its details and read the status or error. See [Background Agent Jobs](../background-jobs/) for status meanings, cancellation, and runtime settings.
