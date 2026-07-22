defmodule Ankole.AIGateway.CompactionPromptTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.CompactionPrompt

  @summary_headings [
    "## Active Task",
    "## Constraints & Preferences",
    "## Completed Actions",
    "## Active State",
    "## In Progress",
    "## Blocked",
    "## Key Decisions",
    "## Resolved Questions",
    "## Pending User Asks",
    "## Remaining Work",
    "## Critical Context"
  ]

  test "creation and update prompts share one summary contract" do
    creation_prompt =
      CompactionPrompt.build_history_user_prompt(%{conversation_text: "new conversation"})

    update_prompt =
      CompactionPrompt.build_history_user_prompt(%{
        conversation_text: "new messages",
        previous_chat_history: "## Active Task\nold task"
      })

    [_previous_history, update_instructions] =
      String.split(update_prompt, "</previous_chat_history>\n\n", parts: 2)

    for prompt <- [creation_prompt, update_instructions] do
      assert prompt =~ "The latest user message after the summary decides what to do now."
      assert prompt =~ "reverse signals"
      refute prompt =~ "<analysis>"

      for heading <- @summary_headings do
        assert length(Regex.scan(~r/^#{Regex.escape(heading)}$/m, prompt)) == 1
      end
    end

    refute creation_prompt =~ "<previous_chat_history>"
    assert update_prompt =~ "<previous_chat_history>"
    refute update_prompt =~ "PRESERVE all"
    assert update_prompt =~ "while it remains accurate and relevant"

    assert update_prompt =~
             "remove details that are stale, irrelevant, resolved, cancelled, or superseded"
  end
end
