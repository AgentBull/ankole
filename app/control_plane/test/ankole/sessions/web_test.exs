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

  test "the Job transport caps one complete page at 2M Unicode code points without caching or duplicating it" do
    url = "https://example.com/long"
    ending = "actual original ending\n"
    text = String.duplicate("🚀\n", 1_000_001) <> ending
    body = %{"results" => [%{"text" => text}]}
    assert {:ok, result} = Web.render(%{web_result_mode: :workspace}, body, [url])
    assert result.output == ""
    assert result.web_cache == %{}

    assert [page] = result.details["results"]
    assert page["total_characters"] == 2_000_002 + String.length(ending)
    assert page["stored_characters"] == 2_000_000
    assert is_integer(page["cache_at"])
    assert page["text"] == String.duplicate("🚀\n", 1_000_000)
    assert String.valid?(page["text"])
    assert String.ends_with?(page["tail"], ending)
    assert byte_size(page["tail"]) <= 160_000
    refute Map.has_key?(page, "next_offset")

    cached = Map.put(page, "metadata", %{"source" => "jina_reader"})

    run = %{
      web_result_mode: :workspace,
      web_cache: %{url => %{at: System.system_time(:millisecond), page: cached}}
    }

    assert {:ok, repeated} = Web.execute(run, %{"name" => "web_fetch"}, %{"urls" => [url]})
    assert [repeated_page] = repeated.details["results"]
    assert repeated_page["repeat_fetch"] == true
    assert repeated_page["source"] == "jina_reader"
    assert repeated_page["total_characters"] == page["total_characters"]
    assert repeated_page["tail"] == page["tail"]
    assert repeated_page["cache_at"] >= page["cache_at"]

    # A single page stays below the 16 MiB Worker channel even when JSON escapes
    # every stored character into its six-byte representation.
    escaped = %{"results" => [%{"text" => String.duplicate(<<0>>, 2_000_001)}]}
    assert {:ok, result} = Web.render(%{web_result_mode: :workspace}, escaped, [url])
    encoded = Ankole.Sessions.ToolResult.encode(result) |> Ankole.JSON.encode!()
    assert byte_size(encoded) < 16 * 1024 * 1024
  end

  test "workspace rendered pages retain their true total and tail before and after a cache hit" do
    url = "https://example.com/rendered"
    text = String.duplicate("article line\n", 60_000) <> "TRUE-END\n"

    page = %{
      "text" => text,
      "total_characters" => String.length(text),
      "stored_characters" => String.length(text),
      "metadata" => %{"source" => "rendered_fallback"}
    }

    assert {:ok, result} =
             Web.render(%{web_result_mode: :workspace}, %{"results" => [page]}, [url])

    assert [full] = result.details["results"]
    assert full["text"] == text
    assert full["total_characters"] == String.length(text)
    assert full["source"] == "rendered_fallback"

    prefix = String.duplicate("a", 2_000_000)
    tail = "ACTUAL-ORIGINAL-END\n"

    capped =
      %{
        page
        | "text" => prefix,
          "total_characters" => 3_000_000,
          "stored_characters" => 2_000_000
      }
      |> Map.put("tail", tail)

    assert {:ok, result} =
             Web.render(%{web_result_mode: :workspace}, %{"results" => [capped]}, [url])

    assert [stored] = result.details["results"]
    assert stored["text"] == prefix
    assert stored["total_characters"] == 3_000_000
    assert stored["stored_characters"] == 2_000_000
    assert stored["tail"] == tail
    cached = Map.put(stored, "metadata", %{"source" => stored["source"]})

    run = %{
      agent_uid: "unused",
      web_result_mode: :workspace,
      web_cache: %{url => %{at: stored["cache_at"], page: cached}}
    }

    assert {:ok, repeated} = Web.execute(run, %{"name" => "web_fetch"}, %{"urls" => [url]})
    assert [repeated_page] = repeated.details["results"]
    assert repeated_page["repeat_fetch"] == true
    assert repeated_page["total_characters"] == 3_000_000
    assert repeated_page["tail"] == tail
  end
end
