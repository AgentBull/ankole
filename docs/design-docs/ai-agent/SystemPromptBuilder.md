# System Prompt Builder

`BullX.AIAgent.SystemPromptBuilder` is a pure renderer for system prompt
sections. It produces deterministic prompt text and metadata used by
`BullX.AIAgent.PromptRenderer`.

## Inputs

The builder receives sections with:

- id;
- content;
- stability: stable or volatile;
- priority;
- tag.

AIAgent profile fields such as soul, mission, instructions, tool guidance, and
runtime time/context notes are converted into sections before rendering.

## Output

The builder returns:

- prompt text;
- section metadata;
- stable prefix byte offset for prompt-cache hints.

Stable sections are rendered before volatile sections. Priority orders sections
inside each stability class.

## Boundaries

The builder does not query MailBox, IMGateway, tools, LLM providers, Brain, or
Skill stores. It does not execute policy.

`BullX.AIAgent.PromptRenderer` owns conversion from conversation messages and
tool results into provider prompt messages.

## Invariants

- Section ids must be unique.
- Rendering is deterministic for the same input.
- Prompt-cache metadata is advisory and not persisted as conversation truth.
- Tests can exercise prompt rendering without MailBox or IMGateway.
