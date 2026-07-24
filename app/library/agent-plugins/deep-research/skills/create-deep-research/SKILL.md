---
name: create-deep-research
description: "Create a Deep Research BackgroundAgentJob for a topic that needs broad evidence or data gathering, careful comparison of many sources, or a forecast of what may happen. Use this Skill when the request states or clearly implies that the human wants this research and is willing to wait. Answer without this Skill when the topic can be resolved quickly without broad research or forecasting. If you are unsure whether the task needs Deep Research or whether the human is willing to wait, ask before invoking this Skill."
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
decisions one by one. For each question, give your recommended answer. Ask one
question at a time and wait for feedback before continuing.

Before the first question, tell the human that they may ask you to directly
create the Job without further clarification and let it decide the unanswered
research choices. Treat such a request as confirmation: stop asking questions
and briefly state your assumptions and the choices left to the Job.

When no unresolved aspect remains, summarize the shared understanding. Do not
create the Job until the human confirms it.

P.s. Remember to remind the human that deep research may take 30-90 minutes, because it may involve multiple rounds of research, analysis, and deduction to produce a high-quality report. If the human is not willing to wait, suggest that they ask for a quick answer instead.

## Start the Job

Call `create_background_job` once with these arguments:

- `title`: a concise label for managing and displaying the Job. 
- `task`: the complete confirmed research request, including your stated assumptions and the research choices left to the Job. Background Agent (Codex) receives this text verbatim as its first user prompt. The `task` must include this exact sentence: "Conduct this Deep Research according to the requirements in the provided AGENTS.md." Include any relevant context, such as the human's goals, constraints, success criteria, and any relevant references.
- `workspace_template_id`: must be 'deep-research' to ensure the Job has the right environment and tools.

The Job automatically receives every current enabled Skill that permits
Background Agent Jobs. Tell the human that the Job started and give them its
`job_id`.

## After the Job starts

When the Job needs access, permission, or a decision that only the human can
make, ask the human. 

If needed, you could use the `send_message_to_background_job` tool to send a steering message to the Job.

When the Job successfully completes, it will send a message to you. Forward that message to the human.
