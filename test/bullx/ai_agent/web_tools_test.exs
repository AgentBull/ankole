defmodule BullX.AIAgent.WebToolsTest do
  use ExUnit.Case, async: false

  alias BullX.AIAgent.Tools.Web

  setup do
    previous_ai_agent = Application.get_env(:bullx, :ai_agent)

    Application.put_env(:bullx, :ai_agent,
      web: [
        search_provider: "exa",
        extract_provider: "jina_reader",
        exa: [api_key: "exa-key"],
        tavily: [api_key: "tavily-key"],
        serpapi: [api_key: "serp-key"],
        jina: [api_key: "jina-key"]
      ]
    )

    Req.Test.stub(__MODULE__, &stub_web/1)

    on_exit(fn ->
      case previous_ai_agent do
        nil -> Application.delete_env(:bullx, :ai_agent)
        value -> Application.put_env(:bullx, :ai_agent, value)
      end
    end)

    :ok
  end

  test "selects configured search and extract adapters independently" do
    assert {:ok, %{id: "exa"}} = Web.select(:search)
    assert {:ok, %{id: "jina_reader"}} = Web.select(:extract)
  end

  test "Exa search sends the expected request and normalizes results" do
    assert {:ok, result} =
             BullX.AIAgent.Tools.Web.Exa.search(%{query: "bullx", limit: 2}, req_seed())

    assert result["success"] == true
    assert result["query"] == "bullx"

    assert [%{"title" => "Exa result", "url" => "https://example.com/exa", "snippet" => "hit"}] =
             result["results"]
  end

  test "Tavily extract sends the expected request and normalizes failures" do
    assert {:ok, result} =
             BullX.AIAgent.Tools.Web.Tavily.extract(
               %{urls: ["https://example.com/tavily"]},
               req_seed()
             )

    assert result["success"] == true

    assert [
             %{"url" => "https://example.com/tavily", "text" => "content"},
             %{"url" => "https://example.com/fail", "error" => "blocked"}
           ] = result["results"]
  end

  test "SerpAPI search sends query parameters and normalizes organic results" do
    assert {:ok, result} =
             BullX.AIAgent.Tools.Web.SerpAPI.search(%{query: "bullx", limit: 1}, req_seed())

    assert [%{"title" => "Serp result", "url" => "https://example.com/serp", "position" => 1}] =
             result["results"]
  end

  test "Jina Reader extract sends one request per URL and normalizes content" do
    assert {:ok, result} =
             BullX.AIAgent.Tools.Web.JinaReader.extract(
               %{urls: ["https://example.com/jina"]},
               req_seed()
             )

    assert [%{"url" => "https://example.com/jina", "title" => "Jina result", "text" => "text"}] =
             result["results"]
  end

  defp req_seed, do: %{web_req_options: [plug: {Req.Test, __MODULE__}]}

  defp stub_web(%Plug.Conn{method: "POST", request_path: "/search"} = conn) do
    body = decode_body(conn)
    assert body["query"] == "bullx"
    assert body["type"] == "auto"
    assert body["numResults"] == 2
    assert body["contents"]["highlights"] == true

    Req.Test.json(conn, %{
      "results" => [
        %{"title" => "Exa result", "url" => "https://example.com/exa", "highlights" => ["hit"]}
      ]
    })
  end

  defp stub_web(%Plug.Conn{method: "POST", request_path: "/extract"} = conn) do
    body = decode_body(conn)
    assert body["urls"] == ["https://example.com/tavily"]
    assert body["extract_depth"] == "basic"
    assert body["format"] == "markdown"
    assert body["include_images"] == false
    assert body["include_favicon"] == false

    Req.Test.json(conn, %{
      "results" => [
        %{"url" => "https://example.com/tavily", "raw_content" => "content"}
      ],
      "failed_results" => [
        %{"url" => "https://example.com/fail", "error" => "blocked"}
      ]
    })
  end

  defp stub_web(%Plug.Conn{method: "GET", request_path: "/search"} = conn) do
    query = URI.decode_query(conn.query_string)
    assert query["engine"] == "google"
    assert query["q"] == "bullx"
    assert query["output"] == "json"
    assert query["api_key"] == "serp-key"

    Req.Test.json(conn, %{
      "organic_results" => [
        %{
          "title" => "Serp result",
          "link" => "https://example.com/serp",
          "snippet" => "serp",
          "position" => 1
        }
      ]
    })
  end

  defp stub_web(%Plug.Conn{method: "POST", request_path: "/"} = conn) do
    body = decode_body(conn)
    assert body["url"] == "https://example.com/jina"

    Req.Test.json(conn, %{
      "data" => %{
        "url" => "https://example.com/jina",
        "title" => "Jina result",
        "content" => "text"
      }
    })
  end

  defp decode_body(conn) do
    conn
    |> Req.Test.raw_body()
    |> Jason.decode!()
  end
end
