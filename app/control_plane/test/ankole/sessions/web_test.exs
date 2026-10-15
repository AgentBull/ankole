defmodule Ankole.Sessions.WebTest do
  use ExUnit.Case, async: true
  alias Ankole.Sessions.Tools.Web

  test "successive byte windows preserve escaped and multibyte text without a Worker or drive" do
    url = "https://example.com/page"
    text = String.duplicate("🚀\n\"quoted\"\\", 2_000)
    body = %{"results" => [%{"url" => url, "title" => "Page", "text" => text}]}

    {parts, _} =
      Enum.reduce_while(1..100, {[], 0}, fn _, {parts, offset} ->
        assert {:ok, result} = Web.render(%{}, body, [url], offset)
        assert byte_size(result.output) <= 8_000
        assert [page] = result.details["results"]
        assert String.valid?(page["text"])
        assert page["total_bytes"] == byte_size(text)
        assert result.web_cache[url].page["text"] == text

        if page["next_offset"] do
          assert page["next_offset"] == offset + byte_size(page["text"])
          assert page["next_offset"] > offset
          {:cont, {[page["text"] | parts], page["next_offset"]}}
        else
          {:halt, {[page["text"] | parts], nil}}
        end
      end)

    assert parts |> Enum.reverse() |> Enum.join() == text
    assert {:ok, invalid} = Web.render(%{}, body, [url], 1)
    assert hd(invalid.details["results"])["error"] == "invalid_result_offset"
  end

  test "script shells and empty pages retain warnings and are not cached" do
    urls = ["https://example.com/empty", "https://example.com/shell"]
    body = %{"results" => [%{"text" => ""}, %{"text" => "Please enable JavaScript"}]}
    assert {:ok, result} = Web.render(%{}, body, urls)

    assert Enum.map(result.details["results"], & &1["render_warning"]) == [
             "empty_text",
             "script_shell"
           ]

    assert result.web_cache == %{}
    assert result.output =~ "different URL"
  end
end
