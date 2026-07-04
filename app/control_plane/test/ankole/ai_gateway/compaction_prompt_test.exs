defmodule Ankole.AIGateway.CompactionPromptTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.CompactionPrompt

  test "system prompt keeps summarization bounded to structured history output" do
    prompt = CompactionPrompt.system_prompt()

    assert prompt =~ "context summarization assistant"
    assert prompt =~ "produce a structured summary"
    assert prompt =~ "Do NOT continue the conversation"
    assert prompt =~ "ONLY output the structured summary"
  end

  test "first compaction prompt preserves the summary section contract" do
    prompt =
      CompactionPrompt.build_history_user_prompt(%{
        conversation_text: "user: stop the old task\nassistant: acknowledged"
      })

    assert prompt =~
             "<conversation>\nuser: stop the old task\nassistant: acknowledged\n</conversation>"

    refute prompt =~ "<previous_chat_history>"
    assert prompt =~ "The messages above are a conversation to summarize."
    assert prompt =~ "## Active Task"
    assert prompt =~ "## Constraints & Preferences"
    assert prompt =~ "## Remaining Work"
    assert prompt =~ "mark the stale work as cancelled or superseded"
    assert prompt =~ "Additional focus:"
    assert prompt =~ "<analysis>"
    assert prompt =~ "Preserve verbatim"
  end

  test "update compaction prompt preserves prior history and delta wording" do
    prompt =
      CompactionPrompt.build_history_user_prompt(%{
        "conversation_text" => "new work happened",
        "previous_chat_history" => "## Active Task\nold work"
      })

    assert prompt =~ "<conversation>\nnew work happened\n</conversation>"
    assert prompt =~ "<previous_chat_history>\n## Active Task\nold work\n</previous_chat_history>"
    assert prompt =~ "PRESERVE all existing information from the previous compressed history"
    assert prompt =~ "## Completed Actions"
    assert prompt =~ "Additional focus:"
    assert prompt =~ "<analysis>"
    assert prompt =~ "Preserve verbatim"
  end
end
