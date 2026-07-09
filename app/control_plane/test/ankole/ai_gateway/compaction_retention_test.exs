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

  defp user_item(text) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }
  end
end
