defmodule YumaSerp.WebSearchAdapterTest do
  use ExUnit.Case, async: false

  alias BullX.AIAgent.{Profile, Tools}
  alias BullX.AIAgent.Tools.Web
  alias BullX.Plugins.{Discovery, Registry}

  setup do
    previous_ai_agent = Application.get_env(:bullx, :ai_agent)
    previous_plugins = Application.get_env(:bullx, :plugins)

    Application.put_env(:bullx, :ai_agent, web: [search_provider: "yuma_serp"])

    Application.put_env(:bullx, :plugins,
      yuma_serp: [
        base_url: "https://serp.yuma.host",
        sources: "all",
        time_range: "1d",
        skip_cache: true
      ]
    )

    Req.Test.stub(__MODULE__, &stub_search/1)

    on_exit(fn ->
      restore_env(:ai_agent, previous_ai_agent)
      restore_env(:plugins, previous_plugins)
    end)

    :ok
  end

  test "plugin registers an enabled web search adapter" do
    registry = plugin_registry()

    assert {:ok, adapter} = Web.select(:search, %{plugin_registry: registry})
    assert adapter.id == "yuma_serp"
    assert adapter.module == YumaSerp.WebSearchAdapter
    assert adapter.supports == [:search]
  end

  test "internal adapter is selected without explicit provider when built-ins are unavailable" do
    Application.put_env(:bullx, :ai_agent, web: [])

    assert {:ok, adapter} = Web.select(:search, %{plugin_registry: plugin_registry()})
    assert adapter.id == "yuma_serp"
  end

  test "enabled internal adapter makes web_search renderable" do
    rendered =
      Tools.enabled_tools(
        %Profile{main_llm: %{}, mission: "search"},
        "caller",
        "agent",
        %{},
        %{plugin_registry: plugin_registry()}
      )

    assert Enum.any?(rendered, &(&1.entry.name == "web_search"))
  end

  test "web search executes through plugin adapter selection" do
    assert {:ok, result} =
             Web.search(
               %{query: "bullx", limit: 2},
               Map.put(req_seed(), :plugin_registry, plugin_registry())
             )

    assert [%{"title" => "BullX"}, %{"title" => "Yuma"}] = result["results"]
  end

  test "search posts to Bull Meta Search and normalizes results" do
    assert {:ok, result} =
             YumaSerp.WebSearchAdapter.search(%{query: "bullx", limit: 2}, req_seed())

    assert result["success"] == true
    assert result["query"] == "bullx"

    assert [
             %{
               "title" => "BullX",
               "url" => "https://example.com/bullx",
               "snippet" => "AgentOS",
               "position" => 1,
               "published_at" => "2026-05-21",
               "source" => "serper",
               "sources" => ["serper", "volc"],
               "score" => 0.99
             },
             %{
               "title" => "Yuma",
               "url" => "https://example.com/yuma",
               "snippet" => "",
               "position" => 2
             }
           ] = result["results"]
  end

  defp req_seed, do: %{web_req_options: [plug: {Req.Test, __MODULE__}]}

  defp plugin_registry do
    {:ok, plugin} = Discovery.discover_app(:yuma_serp, modules: [YumaSerp.Plugin])
    {:ok, registry} = Registry.build([plugin], ["yuma_serp"])
    registry
  end

  defp stub_search(%Plug.Conn{method: "POST", request_path: "/search"} = conn) do
    body = conn |> Req.Test.raw_body() |> Jason.decode!()

    assert body["q"] == "bullx"
    assert body["sources"] == "all"
    assert body["timeRange"] == "1d"
    assert body["top"] == 2
    assert body["skip_cache"] == true

    Req.Test.json(conn, %{
      "query" => "bullx",
      "items" => [
        %{
          "title" => "BullX",
          "url" => "https://example.com/bullx",
          "snippet" => "AgentOS",
          "publishedAt" => "2026-05-21",
          "primarySource" => "serper",
          "sources" => ["serper", "volc"],
          "rerankScore" => 0.99
        },
        %{"title" => "Yuma", "url" => "https://example.com/yuma"},
        %{"title" => "Overflow", "url" => "https://example.com/overflow"}
      ]
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:bullx, key)
  defp restore_env(key, value), do: Application.put_env(:bullx, key, value)
end
