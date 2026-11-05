---
title: Todo and clarify
section: Developer guide
order: 124
description: Control-plane task lists, decision questions, and the separate Codex Job input path.
---

`todo` and `clarify` are control-plane tools owned by `Ankole.Sessions.Tools.Session`. When an Agent invokes either tool, the Session Driver validates its arguments, records the model-visible tool result through AIGateway, and applies the state transition to the active run.

## Task list

`todo` reads, replaces, or merges the current run's task list by item ID. Each item carries a status of `pending`, `in_progress`, `completed`, or `cancelled`, up to a maximum of `256` items. System instructions direct the Agent to create a task list on multi-step work of three or more steps, order items by priority, keep only one item `in_progress` at a time, mark items `completed` immediately after finishing them, and revise the item when a step fails.

Because the task list is ephemeral working state inside `Ankole.Sessions.Run` rather than organizational memory, crash recovery reconstructs it from the successful `todo` calls recorded in the active run's history, and a new Session never inherits another Session's list. Any knowledge meant to persist across Sessions belongs in [Brain](../brain/).

## One decision question

`clarify` asks a single self-contained question whenever the user's answer is required before choosing an outcome or next action. Before calling `clarify`, the Agent checks the request and prior conversation so it never re-asks a stated preference or interrupts work when a safe, low-risk default applies.

Questions can be open-ended or present two to four distinct choices—capped at `2,000` characters for the question, `200` characters per choice label, and `500` characters per optional choice description. Whenever the user should be able to decline the proposed action, the Agent includes an explicit no-action choice.

When `clarify` succeeds, the Driver records the normalized question and choices and terminates the current turn immediately—the Agent calls no further tools and emits no separate text reply. In native **Pod Chat**, the control plane persists the snapshot under `rich_content["clarify"]` and renders an interactive **`ChoiceCard`** whose state advances through `pending -> answered | superseded` (asking a newer question from the same Agent marks any earlier unresolved card `superseded`). Any room member can answer directly on the `ChoiceCard`—selecting an option or submitting text under first-answer-wins locking, where concurrent submissions receive HTTP `409`—or reply with a normal message in Pod Chat or an external chat channel to start the continuation turn. Both the question and the accepted answer remain in the durable conversation history.

## Structured forms

When an answer needs several typed values, the Agent passes `fields` instead of `choices`. A form holds one to five fields. Each field has a snake_case `id`, a `label` of up to 80 characters, an optional `help` hint of up to 200 characters, `required` (default `true`), an optional prefilled `default`, and one type: `text` (one line or `multiline`, with `max_length` up to `1,000` and a default of `200`), `number` (`integer`, `min`, `max`, and a `unit` label), `date` (`YYYY-MM-DD`, with optional `min` and `max`), `select` or `multi_select` (two to ten options, each with a `value` and a `label`; `multi_select` also takes `min_items` and `max_items`), or `boolean`. At least one field must be required. The control plane rejects a definition with repeated IDs or option values, a minimum above its maximum, an invalid default, or no required field, and returns the reason to the Agent so that it can correct the call.

In Pod Chat, the `ChoiceCard` renders the form with typed inputs. The control plane validates every submission again: an invalid submission shows an error under each affected field and keeps the question open, and the first valid submission answers it. The room shows the answer as a one-line summary built from the field labels, and the Agent receives that summary together with the typed values as JSON, where select fields carry option values. A member who prefers to answer in their own words can still open the question in the composer.

Feishu/Lark and Microsoft Teams render the form directly in the reply card, with a button that opens the same form in Pod. The control plane validates each card submission: an invalid one keeps the question open and names the fields to fix, as a toast in Feishu/Lark or as a reply in Teams, and the first valid one answers it. Feishu/Lark and Teams then replace the form with the answer summary. Other external chat channels receive the question, the field labels, and the Pod link (`/?interaction=<id>`). Opening the link shows the form in a dialog without answering it, and the question stays open until someone submits a valid form, on the card or in Pod, or replies in the channel.

## Background Jobs and operation

Native Codex Jobs use their own human-input lifecycle: when a Job requests user input, Ankole transitions it to `waiting_on_user` and releases its active Worker slot until the owner's reply resumes it; see [Background Agent Jobs](../background-agent-jobs/).

Neither task-list behavior nor `clarify` turn termination exposes separate Console tuning flags—adjust the Agent's `AGENTS.md`, or enabled Skills when you want to change how eagerly it plans or asks questions. See [Agents](../agents/) and [The agent loop](../agent-loop/).
