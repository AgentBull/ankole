defmodule Ankole.AIGateway.CompactionPrompt do
  @moduledoc """
  Prompt text for AIGateway-owned history compaction.

  These prompts are the Elixir home for the former worker-side
  `compression-prompt.ts` contract. They intentionally frame summaries as
  reference state, not as instructions to continue stale work.
  """

  @compaction_focus_instructions """
  First, in an <analysis> block, walk the conversation chronologically and note each step's intent, decisions, and any errors and their fixes. This block is scratch work and will be discarded. Then write the summary. Preserve verbatim - never paraphrase - file paths, function and identifier names, error messages, command lines, and IDs/UUIDs; when the latest task is unfinished, quote its exact instruction so work resumes without drift.
  """

  @summarization_system_prompt """
  You are a context summarization assistant. Your task is to read a conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified.

  Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
  """

  @summarization_prompt """
  The messages above are a conversation to summarize. Create a structured compressed previous chat history summary that another LLM will use as reference background.

  The summary is not an instruction to continue old work by itself. The latest user message after the summary decides what to do now. If later messages include reverse signals such as stop, undo, rollback, never mind, just verify, or a topic change, mark the stale work as cancelled or superseded instead of preserving it as active.

  Use this EXACT format:

  ## Active Task
  [The current task, or "(none)" if no task remains active.]

  ## Constraints & Preferences
  - [Any constraints, preferences, or requirements mentioned by user]
  - [Or "(none)" if none were mentioned]

  ## Completed Actions
  - [x] [Completed tasks/changes]
  - [Or "(none)" if no meaningful actions were completed]

  ## Active State
  - [Current files, processes, tools, data, environment, or UI state needed to resume]
  - [Or "(none)" if not applicable]

  ## In Progress
  - [ ] [Current work]
  - [Or "(none)" if no work is in progress]

  ## Blocked
  - [Issues preventing progress, if any]
  - [Or "(none)" if not blocked]

  ## Key Decisions
  - **[Decision]**: [Brief rationale]
  - [Or "(none)" if none were made]

  ## Resolved Questions
  - [Questions that were answered or choices that were settled]
  - [Or "(none)" if none]

  ## Pending User Asks
  - [Explicit requests from the user that still need response/action]
  - [Or "(none)" if none]

  ## Remaining Work
  1. [What remains to complete the active task]
  2. [Or "(none)" if nothing remains]

  ## Critical Context
  - [Any data, examples, or references needed to continue]
  - [Or "(none)" if not applicable]

  Keep each section concise. Preserve exact file paths, function names, and error messages.
  """

  @update_summarization_prompt """
  The messages above are NEW conversation messages to incorporate into the existing compressed previous chat history provided in <previous_chat_history> tags.

  Update the existing structured compressed previous chat history with new information. RULES:
  - PRESERVE all existing information from the previous compressed history
  - ADD new progress, decisions, and context from the new messages
  - UPDATE "Completed Actions", "In Progress", and "Remaining Work" based on what was accomplished
  - PRESERVE exact file paths, function names, and error messages
  - If something is no longer relevant, you may remove it
  - If the new messages include reverse signals such as stop, undo, rollback, never mind, just verify, or a topic change, mark stale work as cancelled or superseded instead of preserving it as active

  Use this EXACT format:

  ## Active Task
  [Preserve or update the current task, or "(none)" if no task remains active.]

  ## Constraints & Preferences
  - [Preserve existing, add new ones discovered]

  ## Completed Actions
  - [x] [Include previously done items AND newly completed actions]
  - [Or "(none)" if no meaningful actions were completed]

  ## Active State
  - [Preserve/update current files, processes, tools, data, environment, or UI state]
  - [Or "(none)" if not applicable]

  ## In Progress
  - [ ] [Current work - update based on progress]
  - [Or "(none)" if no work is in progress]

  ## Blocked
  - [Current blockers - remove if resolved]
  - [Or "(none)" if not blocked]

  ## Key Decisions
  - **[Decision]**: [Brief rationale] (preserve all previous, add new)
  - [Or "(none)" if none]

  ## Resolved Questions
  - [Preserve/add questions that were answered or choices that were settled]
  - [Or "(none)" if none]

  ## Pending User Asks
  - [Explicit requests from the user that still need response/action]
  - [Or "(none)" if none]

  ## Remaining Work
  1. [Update based on current state]
  2. [Or "(none)" if nothing remains]

  ## Critical Context
  - [Preserve important context, add new if needed]

  Keep each section concise. Preserve exact file paths, function names, and error messages.
  """

  @spec system_prompt() :: binary()
  def system_prompt, do: clean(@summarization_system_prompt)

  @spec build_history_user_prompt(map()) :: binary()
  def build_history_user_prompt(input) when is_map(input) do
    conversation_text = map_get(input, :conversation_text) || ""
    previous_chat_history = map_get(input, :previous_chat_history)

    base_prompt =
      if present?(previous_chat_history) do
        @update_summarization_prompt
      else
        @summarization_prompt
      end
      |> with_compaction_focus()

    sections = ["<conversation>\n#{conversation_text}\n</conversation>"]

    sections =
      if present?(previous_chat_history) do
        sections ++
          ["<previous_chat_history>\n#{previous_chat_history}\n</previous_chat_history>"]
      else
        sections
      end

    Enum.join(sections ++ [base_prompt], "\n\n")
  end

  defp with_compaction_focus(base_prompt) do
    "#{clean(base_prompt)}\n\nAdditional focus: #{clean(@compaction_focus_instructions)}"
  end

  defp clean(text) when is_binary(text), do: String.trim(text)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp map_get(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
