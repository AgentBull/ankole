# Context Compression And Caching

AIAgent compression creates summary messages over conversation history. It does
not mutate IMGateway facts, MailBox entries, or raw conversation messages.

The implementation lives in `BullX.AIAgent.Compression`,
`BullX.AIAgent.Conversations`, and prompt rendering modules.

## Summary Model

Summaries are `conversation_messages` rows with:

- role `assistant`;
- kind `summary`;
- status `complete`;
- `covers_range.from_id`;
- `covers_range.to_id`;
- content containing a `summary_text` block;
- metadata including `source_leaf_message_id`,
  `original_dialogue_time_range`, and `compression`.

Raw messages remain in PostgreSQL. Rendering chooses the latest compatible
summary overlay for a branch instead of deleting covered messages.

## Triggering

Compression can be triggered manually by the `/compress` command when no
generation is active.

Runner can trigger automatic compression when provider errors look like context
overflow. Automatic compression is retried a bounded number of times during the
run.

The profile controls:

- `context.compression_threshold_ratio`
- `context.max_turns`
- compression LLM selection

## Compression Range

Compression excludes:

- generating messages;
- summary messages;
- ambient normal messages.

It compresses complete dialogue ranges. If the branch changed or there is no
eligible interval, compression returns diagnostics rather than corrupting
history.

## Prompt Caching

`BullX.AIAgent.SystemPromptBuilder` marks stable and volatile prompt sections
and exposes stable-prefix metadata. Provider prompt-cache hints are request
diagnostics only; they are not Conversation truth.

## Large Tool Results

Compression can compact older large tool results outside the protected tail so
prompt rendering stays within the effective model context window.

## Invariants

- Compression never deletes raw conversation messages.
- Compression never mutates IMGateway facts.
- Compression never creates or routes MailBox entries.
- Summary overlays are renderer behavior, not a replacement storage model.
