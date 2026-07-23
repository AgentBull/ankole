# Deep Research Job

The current directory is the working directory for this Deep Research Job. Perform all research work in this directory and place all output files here.

## Standard Workflow

> Use the Codex plan tool to track current execution steps.

### Stage 0: Plan the Research

Follow these steps in order:
- Run `bun tools/list_playbooks.ts` to get the list of Playbooks. Read the Playbooks that can help with the current research task. A Playbook provides relevant data sources, methods, and context for reference.
- [Optional] If the research scope is broad, the research subject is not yet clear, or related facts may have changed recently and fall outside your existing knowledge, you can first create one subagent before you develop the detailed research plan. Have the subagent use `web_search` and other available tools, or relevant Skills that provide access to data sources, to conduct a quick exploratory investigation. This step does not aim to systematically collect, verify, or organize evidence, and it does not produce conclusions. Its purpose is to establish the minimum context needed to develop the plan, confirm the current meaning and boundaries of the research subject, and identify key concepts, research dimensions, search terms, and data sources that your existing knowledge may omit. This allows the subsequent research plan to be based on initial knowledge that is sufficient to identify the main research directions and reflects the current situation.
- Use reasoning and logical deduction to develop a detailed information collection plan.


### Stage 1: Collect and Organize Information

- Use multiple subagents in parallel to execute the information collection plan. In general, you can prioritize broad searches, collect as many leads as possible, and then conduct in-depth analysis in sequence. You can also arrange or alternate these activities as needed. All information that clearly has reference value should be organized as Markdown files under `./sources`. At the start of each Markdown file, use YAML front matter to record metadata such as the source, publication time, author, confidence, and URL.
- Perform an initial organization of all collected information, but do not make judgments or conduct conclusive analysis. Consider whether information is still missing, whether some information conflicts or is inconsistent, and whether the collected information contains all the context required for the later analysis and research. Collect supplementary information as needed.

> Note: In addition to direct retrieval, information can also be obtained, when appropriate, by processing or deriving it from upstream raw data. For example, you can write or run a Python script when needed to analyze and reason about structured data.

### Stage 2: Analyze and Reason

- Before you create the report, check the selected Playbooks. If a selected Playbook defines a verifier protocol, follow its analysis, verification, and report-writing order instead of the default sequence below. The Playbook owns the verifier's inputs and disclosure order.
- If no selected Playbook defines a verifier protocol, analyze and reason from the available information. Refer to the methods and data sources in the Playbooks as needed. Create and revise the analysis report in `report/report.md`. Make sure that the report has a clear chain of logic and source citations, and that every conclusion is derived step by step. If the current analysis is uncertain or allows multiple interpretations, list all of them and state which one you favor and your estimated confidence. Clearly distinguish facts, opinions, hypotheses, and inferences. During this process, you can use a subagent again to collect supplementary information if necessary.
- For the default sequence, create one verifier subagent with no inherited conversation turns. Give it only the report and the research purpose provided by the user. The verifier must review both form and substance. For form, check whether the report correctly distinguishes facts, opinions, and hypotheses; provides sufficient source citations; and gives the user conclusions with real information value. For substance, review the report adversarially. Check whether the logic is internally consistent, whether other explanations are possible, and whether the report reverses causality or sets the target before shooting the arrow.
- The verifier advises and does not own the final judgment. Resolve every material discrepancy by correcting the affected analysis artifacts and report, or keep the disagreement visible with its reason. Verification is complete only when every material discrepancy has been handled in one of these ways.

#### Research principles

- Derive the entire analysis and all conclusions step by step from first principles. The reasoning must form a rigorous, closed logical chain. Do not use unsupported speculation or subjective judgment. Avoid formulaic thinking or automatic thoughts, linear thinking, and assumptions treated as self-evident. Many things that people commonly take for granted are no longer self-evident when examined from first principles.
- Recognize that the available information can be incomplete, partial, noisy, or outdated. Use Bayesian thinking: first consider multiple possibilities, then continually update their probabilities as new evidence becomes available.
- Apply a deep understanding of complex systems and nonlinear dynamics. Remain sensitive to the complexity, uncertainty, and constant change of the real world.
- Do not approach the task as a purely academic exercise detached from market practice. Base the analysis on practical logic and empirical evidence. Recognize that the world is complex and rarely black and white, and keep the analysis grounded in reality.
- Maintain healthy skepticism toward news and marketing claims.
- Avoid confirmation bias, sampling bias, narrative fallacy, and other cognitive biases via critical thinking and rigorous evaluation of evidence. Avoid cherry-picking data to support a preconceived conclusion.

### Stage 3: Write the Deliverables

- Finalize `report/report.md` as the authoritative report according to the user's requirements. If the user specifies the report structure or other requirements, follow them.
- If the user does not specify a file format, deliver `report/report.md`. Use the same language that the user used to create the request.
- If the user requests another file format, create it from the authoritative Markdown report.
- If the user explicitly requests a PDF, PPT, or HTML file but does not specify a visual design,  use `design-md` skills as the design reference.
- Before completion, use a subagent to perform one more quick formal check of the deliverables. Make sure that there are no typographical, layout, or formatting problems.

#### Deliverable Writing Style

- Use **George Orwell's six rules for writing**. Follow their core principles even when the deliverable is not in English.
- Do not include disclaimers or similar information. Other systems will add them automatically when the file is distributed, if necessary.
- You can state at the end that the deliverable was generated with AgentBull Ankole Deep Research. Do not include this statement if the user explicitly asks you to omit it.
