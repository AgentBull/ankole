defmodule Ankole.AIGateway.MaxToolCallsTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.MaxToolCalls

  test "omitted and null limits stay unlimited, while the native Responses resolver passes through" do
    assert is_nil(MaxToolCalls.new(nil, :openai_chat_completions))
    assert is_nil(MaxToolCalls.new(nil, :openai_responses))
    assert is_nil(MaxToolCalls.new(2, :openai_responses))
    assert is_nil(MaxToolCalls.new(2, "openai_responses"))
    assert is_nil(MaxToolCalls.new(2, :hosted_responses))
    assert is_nil(MaxToolCalls.new(2, "hosted_responses"))

    assert %MaxToolCalls{limit: 2} =
             MaxToolCalls.new(2, :openai_chat_completions)
  end

  test "client-executed function, custom, and computer calls never consume the limit" do
    policy = MaxToolCalls.new(0, :anthropic_messages)

    policy =
      MaxToolCalls.observe(policy, output_item_done("function_call", "fc_1", 1))

    policy =
      MaxToolCalls.observe(policy, output_item_done("custom_tool_call", "ctc_1", 2))

    policy =
      MaxToolCalls.observe(policy, output_item_done("computer_call", "computer_1", 3))

    refute MaxToolCalls.stop?(policy)

    assert MaxToolCalls.details(policy) == %{
             "limit" => 0,
             "observed" => 0,
             "overshoot" => 0
           }
  end

  test "zero is enforced late after the first provider-executed built-in call" do
    policy =
      0
      |> MaxToolCalls.new(:openai_chat_completions)
      |> MaxToolCalls.observe(output_item_done("web_search_call", "ws_1", 1))

    assert MaxToolCalls.stop?(policy)

    assert MaxToolCalls.details(policy) == %{
             "limit" => 0,
             "observed" => 1,
             "overshoot" => 1
           }
  end

  test "already-started parallel built-in calls are allowed to finish and report overshoot" do
    policy = MaxToolCalls.new(1, :openai_chat_completions)

    policy = MaxToolCalls.observe(policy, output_item_added("web_search_call", "ws_1", 0, 1))
    policy = MaxToolCalls.observe(policy, output_item_added("web_search_call", "ws_2", 1, 2))
    policy = MaxToolCalls.observe(policy, output_item_done("web_search_call", "ws_1", 3))

    refute MaxToolCalls.stop?(policy)

    policy = MaxToolCalls.observe(policy, output_item_done("web_search_call", "ws_2", 4))

    assert MaxToolCalls.stop?(policy)

    assert MaxToolCalls.details(policy) == %{
             "limit" => 1,
             "observed" => 2,
             "overshoot" => 1
           }
  end

  test "duplicate lifecycle events do not double count one built-in call" do
    policy = MaxToolCalls.new(1, :anthropic_messages)
    added = output_item_added("code_interpreter_call", "code_1", 0, 1)
    done = output_item_done("code_interpreter_call", "code_1", 2)

    policy = MaxToolCalls.observe(policy, added)
    policy = MaxToolCalls.observe(policy, added)
    policy = MaxToolCalls.observe(policy, done)
    policy = MaxToolCalls.observe(policy, done)

    assert MaxToolCalls.stop?(policy)
    assert MaxToolCalls.details(policy)["observed"] == 1
    assert MaxToolCalls.details(policy)["overshoot"] == 0
  end

  defp output_item_added(type, id, output_index, sequence_number) do
    %{
      "type" => "response.output_item.added",
      "output_index" => output_index,
      "sequence_number" => sequence_number,
      "item" => %{"type" => type, "id" => id, "status" => "in_progress"}
    }
  end

  defp output_item_done(type, id, sequence_number) do
    %{
      "type" => "response.output_item.done",
      "sequence_number" => sequence_number,
      "item" => %{"type" => type, "id" => id, "status" => "completed"}
    }
  end
end
