defmodule Ankole.AIGateway.CompactionRetentionTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.CompactionRetention

  test "selects newest user originals and truncates the next older one within budget" do
    old = user_item("old " <> String.duplicate("x", 80))
    middle = user_item("middle")
    latest = user_item("latest")

    {selected, used_tokens} =
      CompactionRetention.collect_user_originals([old, middle, latest], 10)

    assert [truncated_old, ^middle, ^latest] = selected
    assert get_in(truncated_old, ["content", Access.at(0), "text"]) =~ "tokens elided"
    assert used_tokens <= 10
  end

  test "truncates the oldest selected item when it only partially fits" do
    first = user_item(String.duplicate("a", 120))
    latest = user_item("latest")

    {selected, 20} = CompactionRetention.collect_user_originals([first, latest], 20)

    assert [truncated, ^latest] = selected
    assert get_in(truncated, ["content", Access.at(0), "text"]) =~ "tokens elided"
  end

  test "keeps image-only user items with one token cost" do
    image = %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_image", "image_url" => "https://files.test/a.png"}]
    }

    assert {[image], 1} == CompactionRetention.collect_user_originals([image], 1)
  end

  test "filters non-user roles" do
    user = user_item("keep")

    {selected, _used_tokens} =
      CompactionRetention.collect_user_originals(
        [
          %{"type" => "message", "role" => "system", "content" => "system"},
          %{"type" => "message", "role" => "assistant", "content" => "assistant"},
          user
        ],
        100
      )

    assert selected == [user]
  end

  test "selects the newest clarify pair with no user message after it" do
    {call, output} = clarify_pair("call_1", "Which market?")

    assert [^call, ^output] =
             CompactionRetention.collect_pending_clarify([
               user_item("analyze the market"),
               call,
               output
             ])
  end

  test "returns nothing when a later user message answered the clarify" do
    {call, output} = clarify_pair("call_1", "Which market?")

    assert [] ==
             CompactionRetention.collect_pending_clarify([
               call,
               output,
               user_item("A shares")
             ])
  end

  test "selects only the newest of several clarify exchanges" do
    {answered_call, answered_output} = clarify_pair("call_1", "Which market?")
    {pending_call, pending_output} = clarify_pair("call_2", "Which horizon?")

    assert [^pending_call, ^pending_output] =
             CompactionRetention.collect_pending_clarify([
               answered_call,
               answered_output,
               user_item("A shares"),
               pending_call,
               pending_output
             ])
  end

  test "ignores a clarify call without its output and non-clarify calls" do
    {call, _output} = clarify_pair("call_1", "Which market?")

    assert [] == CompactionRetention.collect_pending_clarify([call])

    assert [] ==
             CompactionRetention.collect_pending_clarify([
               %{"type" => "function_call", "name" => "web_search", "call_id" => "call_2"},
               %{"type" => "function_call_output", "call_id" => "call_2", "output" => "{}"}
             ])
  end

  defp user_item(text) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }
  end

  defp clarify_pair(call_id, question) do
    call = %{
      "type" => "function_call",
      "name" => "clarify",
      "call_id" => call_id,
      "arguments" => ~s({"question":"#{question}"})
    }

    output = %{
      "type" => "function_call_output",
      "call_id" => call_id,
      "output" => ~s({"tool":"clarify","question":"#{question}","choices":[]})
    }

    {call, output}
  end
end
