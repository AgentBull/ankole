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

Interview the human relentlessly about every unresolved aspect of the research
request until you reach a shared understanding. You have reached that
understanding only when the research goal and intent, any applicable success
criteria, and all relevant constraints are clear.

Build this understanding from the request, conversation, relevant memory,
first-principles reasoning, and the available environment and tools. If a fact
can be found in the environment or with tools, look it up rather than asking.
The decisions, though, are the human's: put each unresolved decision to them and
wait for their answer.

Walk down each branch of the decision tree, resolving dependencies between
decisions one by one, starting with the question whose wrong answer wastes the
most work — usually what the research must establish, rarely the output format.
For each question, give your recommended answer. Ask one question at a time and
wait for feedback before continuing.

Before the first question, tell the human that they may ask you to directly
create the Job without further clarification and let it decide the unanswered
research choices. Treat such a request as confirmation: stop asking questions
and briefly state your assumptions, what the Job will treat as given, and the
choices left to the Job.

When no unresolved aspect remains, show the human the requirements you are
about to send and what the Job will treat as given. Do not create the Job until
the human confirms them.

P.s. Remember to remind the human that deep research may take 30-90 minutes, because it may involve multiple rounds of research, analysis, and deduction to produce a high-quality report. If the human is not willing to wait, suggest that they ask for a quick answer instead. 

## Start the Job

Call `create_background_job` once with these arguments:

- `title`: a concise label for managing and displaying the Job. 
- `task`: the complete confirmed research request, including your stated assumptions and the research choices left to the Job. Open the task with the intent, before any requirement: who the research is for and what decision or outcome the output enables, in one or two sentences — the Job produces better judgments when it knows why the answer matters. Name in that opening what the research must establish, and, when the human's own material settles something the Job would otherwise investigate, what it supplies as given: a specification, rules, or parameters the human has already settled are premises, not claims for the Job to check, unless the human asks you for that check. Then state each requirement the human stated or confirmed, exactly once. Everything else that belongs in the task, including anything that first occurs to you while you write it, goes in a separate list of choices you leave to the Job, so the Job can tell an obligation from an option. The Job's AGENTS.md already owns research method, verification, and its own caution, so do not add a check or a prohibition here: it runs on top of the Job's own and only makes the report more hedged. State each requirement as what the deliverable must satisfy; a how belongs in the task only when the human asked for that how. Background Agent (Codex) receives this text verbatim as its first user prompt. The `task` must include this exact sentence: "Conduct this Deep Research according to the requirements in the provided AGENTS.md." Include any relevant context, such as the human's goals, constraints, success criteria, and any relevant references. Write a length the human states, such as a page count or a word count, as an approximate target unless the human asks for an exact value. "A 3-page PDF" means a report of approximately 3 pages, not exactly 3 pages.
- `workspace_template_id`: must be 'deep-research' to ensure the Job has the right environment and tools.

The Job automatically receives every current enabled Skill that permits
Background Agent Jobs. Tell the human that the Job started and give them its
`job_id`.

## After the Job starts

When the Job needs access, permission, or a decision that only the human can
make, ask the human. 

If needed, you could use the `send_message_to_background_job` tool to send a steering message to the Job.

When the Job successfully completes, it will send a message to you. Read `report/report.md` in the Job workspace before you forward the result: the goal is a delivered report that serves the confirmed research purpose. If the report states a gap or limitation that defeats that purpose, tell the human, and steer the Job when you can supply what it lacked — new information you hold, or a decision from the human.
