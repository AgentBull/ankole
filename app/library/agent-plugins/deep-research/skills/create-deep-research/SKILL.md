---
name: create-deep-research
description: "Create a Deep Research BackgroundAgentJob for a topic that needs broad evidence or data gathering, comparison of many sources, or a forecast of what may happen. Use this Skill when the request states or implies that the human wants this research and will wait for it. Answer directly when the topic resolves quickly without broad research or forecasting; when unsure on either point, ask first."
default_enabled: true
ankole-runtime: main
category: research
tags: [Research, Evidence, Forecast, ACH, Retrospect]
---

# Create Deep Research Task

## Clarify the request

Establish the research goal and intent, the success criteria, and the
constraints from the request, the conversation, relevant memory, and what the
environment and tools can tell you. If a fact can be found with a tool, look it
up rather than asking.

Ask the human only about a decision that changes the conclusion, the
authorization, or the deliverable scope and that you cannot settle yourself.
Ask one question at a time, give your recommended answer, and wait for the
reply; start with the question whose wrong answer wastes the most work, usually
what the research must establish, rarely the output format. A request that is
already explicit and within an existing authorization, such as a monitoring or
research task the human has already defined, needs no confirmation round: state
the assumptions you make and create the Job.

Before the first question, tell the human that they may ask you to create the
Job without further clarification. Treat such a request as confirmation: stop
asking, state your assumptions, what the Job will treat as given, and the
choices left to the Job, then create the Job.

Tell the human how long this Job is likely to take from what the task needs; a
full research run with several collection and verification rounds commonly
takes tens of minutes. If the human is not willing to wait, offer a quick answer
instead.

## Start the Job

Call `create_background_job` once with these arguments:

- `title`: a concise label for managing and displaying the Job. 
- `task`: the complete confirmed research request, including your stated assumptions and the research choices left to the Job. Open the task with the intent, before any requirement: who the research is for and what decision or outcome the output enables, in one or two sentences — the Job produces better judgments when it knows why the answer matters. Name in that opening what the research must establish, and, when the human's own material settles something the Job would otherwise investigate, what it supplies as given: a specification, rules, or parameters the human has already settled are premises, not claims for the Job to check, unless the human asks you for that check. Then state each requirement the human stated or confirmed, exactly once. Everything else that belongs in the task, including anything that first occurs to you while you write it, goes in a separate list of choices you leave to the Job, so the Job can tell an obligation from an option. The Job's AGENTS.md already owns research method, verification, and its own caution, so do not add a check or a prohibition here: it runs on top of the Job's own and only makes the report more hedged. State each requirement as what the deliverable must satisfy; a how belongs in the task only when the human asked for that how. Background Agent (Codex) receives this text verbatim as its first user prompt. The `task` must include this exact sentence: "Conduct this Deep Research according to the requirements in the provided AGENTS.md." Include any relevant context, such as the human's goals, constraints, success criteria, and any relevant references. Write a length the human states, such as a page count or a word count, as an approximate target unless the human asks for an exact value. "A 3-page PDF" means a report of approximately 3 pages, not exactly 3 pages.
- `workspace_template_id`: must be 'deep-research' to ensure the Job has the right environment and tools.

The Job automatically receives every current enabled Skill that permits
Background Agent Jobs. Tell the human that the Job started, with its `job_id`,
only after the tool confirms the creation; a failed creation is reported as a
failure, not as a started Job.

## After the Job starts

When the Job needs access, permission, or a decision that only the human can
make, ask the human. 

If needed, you could use the `send_message_to_background_job` tool to send a steering message to the Job.

When the Job completes, its result wakes you with the report's real paths. The
Job has already verified the report against the task, so deliver from that
result under the background job policy: attach the named files and report the
outcome. If the result states a gap or limitation that defeats the confirmed
research purpose, tell the human, and continue the Job when you can supply what
it lacked — new information you hold, or a decision from the human.

## Register resolvable predictions

After you forward the result, register each judgment in the report that
carries a resolution date as one Brain take, so the instance can grade it when
the date arrives. For each such judgment, call `remember` once:

- `claim`: the falsifiable statement, quoted or tightly paraphrased from the
  report, so a reader on the resolution date can mark it true or false.
- `kind`: `bet` when the report commits to an outcome, `take` otherwise.
- `weight`: the report's stated confidence, rounded to a 0.05 step.
- `until_date`: the report's resolution date (ISO date).
- `entity`: the page of the subject the prediction is about, when one exists.
- `scope`: follow ConfidentialityPolicy.md as with any memory write.
- `provenance`: "deep research job <job_id>, report/report.md" plus the report
  section.

Register only judgments the report itself dates. Do not invent resolution
dates, and do not register process notes or hedged background observations.
