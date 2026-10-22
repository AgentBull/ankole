---
title: Todo and clarify
section: Developer guide
order: 124
description: Control-plane task lists, decision questions, and the separate Codex Job input path.
---

`todo` and `clarify` are control-plane tools owned by `Ankole.Sessions.Tools.Session`. The Driver validates their arguments, stores their model-visible results through AIGateway, and applies their effects to the current run.

## Task list

`todo` reads, replaces, or merges the current list by item ID. Its states are `pending`, `in_progress`, `completed`, and `cancelled`; the declaration accepts at most 256 items. The instructions call for a list on complex tasks of three or more steps, priority order, one item in progress, immediate completion marking, and a revised item after a failed step.

The list is working state in `Ankole.Sessions.Run`, not organizational knowledge. Recovery reconstructs it from successful recorded tool calls in the current run's history. A new Session does not inherit another Session's list. Knowledge that must be shared across Sessions belongs to [Brain](../brain/).

## One decision question

`clarify` asks one self-contained question when its answer is necessary to choose the result or next action. The Agent uses the request and prior conversation before asking. It does not repeat an existing preference or interrupt work when a safe low-risk default is available.

The question can be open-ended or provide two to four distinct choices. The question limit is 2,000 characters, each label 200, and each optional description 500. An action that the user can decline includes a no-action choice.

A successful result records the normalized question and choices and ends the current turn. The Agent calls no further tools and adds no final answer; the user's next message starts the continuation. The question and reply remain in the durable conversation record.

## Background Jobs and operation

Native Codex Jobs use their own input-request path. A request for human input puts a Job into `waiting_on_user` and releases its running slot; the owner's reply resumes it. This is a Job lifecycle contract. See [Background Agent Jobs](../background-agent-jobs/).

Planning state and turn termination have no Console tuning flags. Change the Agent's guidance and capabilities when its choice to plan or ask needs adjustment. See [Agents](../agents/) and [The agent loop](../agent-loop/).
